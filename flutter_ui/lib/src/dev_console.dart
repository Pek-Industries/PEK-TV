import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'app_update.dart';
import 'art_cache.dart';
import 'common.dart';
import 'fields.dart' show DpadEscape;
import 'store.dart';
import 'tokens.dart';
import 'widgets.dart';

/// Developer mode: a console inside the app that shows what is going on behind the scenes (everything the app prints, errors,
/// and the C++ server's own log) and runs commands.
///
///  * Off by default. Tapping "Installed version" in Settings > Advanced 7 times asks to turn it on (see [DevUnlockTap]).
///  * Commands run in the app's own Android user (no root): they can read and delete the app's data and break the app, which
///    is the point of a developer console. Nothing here is reachable from the network: it runs inside the app only, there is
///    no server route for it.
///  * The log buffer is always filled (it is small), so what happened before developer mode was turned on is there too.
class DevConsole {
  static const _key = 'pek_dev_mode';
  static const _maxLines = 4000;

  /// Whether developer mode is on (kept across restarts).
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// Bumped (at most about 6 times a second) when lines were added, so the page can redraw.
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  /// True while a command is running.
  static final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  static final List<String> lines = [];
  static final List<String> history = [];

  static Process? _proc;
  static Timer? _tail;
  static int _tailPos = 0;
  static bool _pending = false;
  static String? _filesDir;

  /// Call once Store is ready.
  static void init() {
    enabled.value = Store.strGet(_key, scoped: false) == '1';
    if (enabled.value) _startTail();
  }

  /// Hooks for errors that nothing else handles. The `print` hook is in main.dart (it has to be on the app's zone).
  static void installErrorHooks() {
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      add('[flutter error] ${details.exceptionAsString()}\n${details.stack ?? ''}');
      prev?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      add('[uncaught] $error\n$stack');
      return false;
    };
  }

  static String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}.${n.millisecond.toString().padLeft(3, '0')}';
  }

  /// Adds text to the log (one line each). Never prints, so it cannot loop with the `print` hook.
  static void add(String text) {
    final stamp = _stamp();
    for (final l in const LineSplitter().convert(text)) {
      lines.add('$stamp $l');
    }
    if (lines.length > _maxLines) lines.removeRange(0, lines.length - _maxLines);
    _bump();
  }

  static void _bump() {
    if (_pending) return;
    _pending = true;
    Timer(const Duration(milliseconds: 160), () {
      _pending = false;
      changed.value++;
    });
  }

  static void clear() {
    lines.clear();
    _bump();
  }

  static Future<void> enable() async {
    await Store.strSet(_key, '1', scoped: false);
    enabled.value = true;
    _startTail();
  }

  static Future<void> disable() async {
    await Store.strSet(_key, '0', scoped: false);
    enabled.value = false;
    _tail?.cancel();
    _tail = null;
  }

  // ---------------------------------------------------------------- the C++ server's log

  static Future<String> _dir() async {
    final known = _filesDir;
    if (known != null) return known;
    String? d;
    try {
      final m = await const MethodChannel('pek/host').invokeMapMethod<String, String>('dirs').timeout(const Duration(seconds: 2));
      d = m?['files'];
    } catch (_) {}
    return _filesDir = d ?? Directory.systemTemp.path;
  }

  static void _startTail() {
    _tail ??= Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  /// The server's stdout / stderr are written to files/hesper/backend.log by the native side (jni_entry.cpp).
  static Future<void> _poll() async {
    try {
      final f = File('${await _dir()}/hesper/backend.log');
      if (!await f.exists()) return;
      final len = await f.length();
      if (len < _tailPos) _tailPos = 0; // the file was started over
      if (len == _tailPos) return;
      var start = _tailPos;
      if (start == 0 && len > 65536) start = len - 65536; // the first time: just the last 64 KB
      final raf = await f.open();
      List<int> bytes;
      try {
        await raf.setPosition(start);
        bytes = await raf.read(len - start);
      } finally {
        await raf.close();
      }
      _tailPos = len;
      for (final l in const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true))) {
        add('[server] $l');
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------- commands

  static const helpText = '''Built-in commands:
  help                 this text
  clear                empty the screen
  info                 version, folders, process
  api /api/...         GET a route of the local server and show the answer
  cache size | clear   the saved pictures and synopses
  wipe YES             delete ALL app data (settings, library, caches) and close the app
Anything else runs in the Android shell (sh), for example:
  ls -la files/hesper    cat files/hesper/backend.log    ps -A    df -h    ping -c 3 tmdb.pekindustries.com
  logcat -d -t 200       (this app's own system log)
Commands run as the app's user, with no root. They can break the app. Stop kills a running command.''';

  static Future<void> run(String input) async {
    final cmd = input.trim();
    if (cmd.isEmpty) return;
    add('\$ $cmd');
    history.remove(cmd);
    history.add(cmd);
    final first = cmd.split(RegExp(r'\s+')).first;
    final rest = cmd.substring(first.length).trim();
    busy.value = true;
    try {
      switch (first.toLowerCase()) {
        case 'help':
          add(helpText);
        case 'clear':
          clear();
        case 'info':
          await _info();
        case 'api':
          await _api(rest);
        case 'cache':
          await _cache(rest);
        case 'wipe':
          await _wipe(rest);
        default:
          await _shell(cmd);
      }
    } catch (e) {
      add('[error] $e');
    } finally {
      busy.value = false;
    }
  }

  /// Ends the running command.
  static void stop() {
    final p = _proc;
    if (p == null) return;
    add('[stopped]');
    p.kill(ProcessSignal.sigkill);
  }

  static Future<void> _info() async {
    final v = await AppUpdate.installedVersion();
    add('version      ${v ?? 'unknown'}');
    add('files dir    ${await _dir()}');
    add('server       ${Api.base}');
    add('system       ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    add('cpus         ${Platform.numberOfProcessors}');
    add('process id   $pid');
    add('log lines    ${lines.length} (server log ${_tail == null ? 'off' : 'on'})');
  }

  static Future<void> _api(String path) async {
    if (path.isEmpty) {
      add('usage: api /api/movies');
      return;
    }
    final p = path.startsWith('/') ? path : '/$path';
    final sw = Stopwatch()..start();
    final r = await http.get(Uri.parse('${Api.base}$p')).timeout(const Duration(seconds: 20));
    var body = utf8.decode(r.bodyBytes, allowMalformed: true);
    try {
      body = const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
    } catch (_) {}
    add('HTTP ${r.statusCode}  ${sw.elapsedMilliseconds} ms  ${r.bodyBytes.length} bytes');
    add(body.length > 6000 ? '${body.substring(0, 6000)}\n... (${body.length - 6000} more characters)' : body);
  }

  static Future<void> _cache(String arg) async {
    switch (arg.toLowerCase()) {
      case 'size':
        final b = await ArtCache.size();
        add('saved pictures: ${(b / (1024 * 1024)).toStringAsFixed(1)} MB');
      case 'clear':
        await ArtCache.clear();
        add('saved pictures and synopses deleted');
      default:
        add('usage: cache size | cache clear');
    }
  }

  static Future<void> _wipe(String arg) async {
    if (arg != 'YES') {
      add('This deletes ALL app data (settings, profiles, library, history, caches) and closes the app.');
      add('Type  wipe YES  to do it.');
      return;
    }
    add('wiping ...');
    for (final base in [await _dir(), (await _cacheDir())]) {
      try {
        await for (final e in Directory(base).list()) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      } catch (_) {}
    }
    try {
      await (await SharedPreferences.getInstance()).clear();
    } catch (_) {}
    add('done, closing the app');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    exit(0);
  }

  static Future<String> _cacheDir() async {
    try {
      final m = await const MethodChannel('pek/host').invokeMapMethod<String, String>('dirs').timeout(const Duration(seconds: 2));
      return m?['cache'] ?? Directory.systemTemp.path;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }

  static Future<void> _shell(String cmd) async {
    final exe = Platform.isAndroid ? '/system/bin/sh' : 'sh';
    final dir = await _dir();
    final p = await Process.start(exe, ['-c', cmd], workingDirectory: Directory(dir).existsSync() ? dir : null);
    _proc = p;
    final out = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(add);
    final err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(add);
    final code = await p.exitCode;
    await out.asFuture<void>().timeout(const Duration(seconds: 1), onTimeout: () {});
    await err.asFuture<void>().timeout(const Duration(seconds: 1), onTimeout: () {});
    _proc = null;
    add('[exit $code]');
  }
}

// ==================================================================== unlock: 7 taps

/// Wrap the "Installed version" text with this: 7 quick taps (7 presses of the centre button on a remote) ask whether to turn
/// developer mode on.
class DevUnlockTap extends StatefulWidget {
  const DevUnlockTap({super.key, required this.child});
  final Widget child;

  @override
  State<DevUnlockTap> createState() => _DevUnlockTapState();
}

class _DevUnlockTapState extends State<DevUnlockTap> {
  int _taps = 0;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _say(String text) {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  Future<void> _tap() async {
    if (DevConsole.enabled.value) {
      _say('Developer mode is already on.');
      return;
    }
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 3), () => _taps = 0); // taps have to follow each other
    _taps++;
    if (_taps < 7) {
      if (_taps >= 3) _say('${7 - _taps} more tap${7 - _taps == 1 ? '' : 's'} to turn on developer mode');
      return;
    }
    _taps = 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Turn on developer mode?'),
        content: const Text(
            'The developer console shows everything going on inside the app and runs commands. Commands can delete data and break the app, and they can make it stop working until you reinstall it or clear its data.\n\nOnly continue if you know what you are doing.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Turn on')),
        ],
      ),
    );
    if (ok == true) {
      await DevConsole.enable();
      if (mounted) _say('Developer mode is on. Open it under Settings > Advanced > Developer.');
    }
  }

  @override
  Widget build(BuildContext context) => PekFocusable(onTap: _tap, child: widget.child);
}

// ==================================================================== Settings > Advanced > Developer

/// Only shown while developer mode is on.
class DevConsoleSection extends StatelessWidget {
  const DevConsoleSection({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    return ValueListenableBuilder<bool>(
      valueListenable: DevConsole.enabled,
      builder: (context, on, _) {
        if (!on) return const SizedBox.shrink();
        return Section(
          title: 'Developer',
          hint: 'Developer mode is on. The console can run commands that break the app.',
          children: [
            Align(alignment: Alignment.centerLeft, child: PekButton(label: 'Open developer console', onTap: () => Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => const DevConsolePage())))),
            SizedBox(height: 0.5 * p.rem),
            Align(alignment: Alignment.centerLeft, child: PekButton(label: 'Turn off developer mode', onTap: DevConsole.disable)),
          ],
        );
      },
    );
  }
}

// ==================================================================== the console

class DevConsolePage extends StatefulWidget {
  const DevConsolePage({super.key});

  @override
  State<DevConsolePage> createState() => _DevConsolePageState();
}

class _DevConsolePageState extends State<DevConsolePage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _follow = true;
  int _histPos = -1;

  @override
  void initState() {
    super.initState();
    DevConsole.changed.addListener(_redraw);
    DevConsole.busy.addListener(_redraw);
    WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
  }

  @override
  void dispose() {
    DevConsole.changed.removeListener(_redraw);
    DevConsole.busy.removeListener(_redraw);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _redraw() {
    if (!mounted) return;
    setState(() {});
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
    }
  }

  void _toEnd() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    // Lines have different heights, so the first jump can fall short: once more after the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients && _follow) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _submit([String? _]) {
    final text = _input.text;
    if (text.trim().isEmpty || DevConsole.busy.value) return;
    _input.clear();
    _histPos = -1;
    _follow = true;
    unawaited(DevConsole.run(text));
  }

  void _older() {
    final h = DevConsole.history;
    if (h.isEmpty) return;
    _histPos = _histPos < 0 ? h.length - 1 : (_histPos > 0 ? _histPos - 1 : 0);
    _input.text = h[_histPos];
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  void _newer() {
    final h = DevConsole.history;
    if (_histPos < 0) return;
    if (_histPos < h.length - 1) {
      _histPos++;
      _input.text = h[_histPos];
    } else {
      _histPos = -1;
      _input.clear();
    }
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  Color _colour(String l, PekScope p) {
    final low = l.toLowerCase();
    if (low.contains('[error') || low.contains('[uncaught') || low.contains('[flutter error') || low.contains('exception') || low.contains('failed')) return const Color(0xFFFF6B6B);
    if (low.contains('slow picture') || low.contains('warn') || low.contains('[stopped')) return const Color(0xFFFFC107);
    if (l.length > 13 && l.substring(13).startsWith('\$ ')) return const Color(0xFF5CD68A);
    if (l.contains('[server]')) return p.tokens.textMuted;
    return p.tokens.text;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final lines = DevConsole.lines;
    final busy = DevConsole.busy.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Developer console'),
        actions: [
          IconButton(
            tooltip: _follow ? 'Stop following new lines' : 'Follow new lines',
            icon: Icon(_follow ? Icons.vertical_align_bottom : Icons.pause_circle_outline),
            onPressed: () {
              setState(() => _follow = !_follow);
              if (_follow) _toEnd();
            },
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: lines.join('\n')));
              if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
            },
          ),
          IconButton(tooltip: 'Clear', icon: const Icon(Icons.delete_outline), onPressed: DevConsole.clear),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: NotificationListener<UserScrollNotification>(
                onNotification: (n) {
                  // Scrolling up by hand stops the following; the button in the top bar starts it again.
                  if (n.direction == ScrollDirection.forward && _follow) setState(() => _follow = false);
                  return false;
                },
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  itemCount: lines.length,
                  itemBuilder: (context, i) => Text(lines[i], style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3, color: _colour(lines[i], p))),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              color: p.tokens.surface,
              child: Row(
                children: [
                  IconButton(tooltip: 'Older command', icon: const Icon(Icons.keyboard_arrow_up), onPressed: _older),
                  IconButton(tooltip: 'Newer command', icon: const Icon(Icons.keyboard_arrow_down), onPressed: _newer),
                  Expanded(
                    child: DpadEscape(
                      controller: _input,
                      child: TextField(
                      controller: _input,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.send,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                      decoration: const InputDecoration(hintText: 'command (type help)', prefixText: '\$ ', isDense: true),
                      onSubmitted: _submit,
                    ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  busy ? FilledButton(onPressed: DevConsole.stop, child: const Text('Stop')) : FilledButton(onPressed: _submit, child: const Text('Run')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
