import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Writes "[exit]" lines to the log (the developer console shows them, and so does `adb logcat -s flutter`) so a Back out of a
/// video can be followed step by step: Back press, the Stop watching? choice, the player closing, which screen is shown next,
/// the app going to the background, and the native side finishing the activity. Debugging aid: remove it once the bug is found.
class ExitTrace {
  static final _t0 = DateTime.now();
  static String? _path; // files/exit_trace.log (Android); the native side starts it over and keeps the older runs in exit_trace_prev.log
  static final List<String> _early = []; // lines written before the folder is known

  static void log(String what) {
    final ms = DateTime.now().difference(_t0).inMilliseconds;
    // ignore: avoid_print
    print('[exit +${ms}ms] $what');
    _toFile('${_wall()} [exit +${ms}ms] $what');
  }

  static String _wall() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}.${n.millisecond.toString().padLeft(3, '0')}';
  }

  /// Written straight away (not buffered): the app may be gone a moment later, and the file is what survives it.
  static void _toFile(String line) {
    final p = _path;
    if (p == null) {
      if (_early.length < 300) _early.add(line);
      return;
    }
    try {
      File(p).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static Future<void> _findFile() async {
    if (!Platform.isAndroid) return;
    try {
      final m = await const MethodChannel('pek/host').invokeMapMethod<String, String>('dirs').timeout(const Duration(seconds: 2));
      final dir = m?['files'];
      if (dir == null) return;
      _path = '$dir/exit_trace.log';
      final early = List<String>.of(_early);
      _early.clear();
      early.forEach(_toFile);
    } catch (_) {}
  }

  /// Pass to `MaterialApp.navigatorObservers`: every route that is pushed, popped or removed.
  static final NavigatorObserver observer = _RouteTrace();

  /// Once, from main(): app lifecycle changes (resumed / inactive / hidden / paused / detached) and every Back or Escape key.
  static void install() {
    _findFile();
    WidgetsBinding.instance.addObserver(_LifecycleTrace());
    HardwareKeyboard.instance.addHandler((e) {
      final k = e.logicalKey;
      if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.browserBack) {
        log('key ${e.runtimeType} ${k.keyLabel.isEmpty ? k.debugName : k.keyLabel}');
      }
      return false; // only watching
    });
  }
}

class _LifecycleTrace with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => ExitTrace.log('app lifecycle: ${state.name}');

  @override
  Future<bool> didPopRoute() async {
    ExitTrace.log('system Back reached Flutter (didPopRoute)');
    return false; // let the normal handling carry on
  }
}

String _name(Route<dynamic>? r) {
  if (r == null) return 'none';
  final n = r.settings.name;
  return '${r.runtimeType}${n == null ? '' : ' "$n"'}';
}

class _RouteTrace extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => ExitTrace.log('route push: ${_name(route)} (over ${_name(previousRoute)})');
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => ExitTrace.log('route pop: ${_name(route)} (now showing ${_name(previousRoute)})');
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => ExitTrace.log('route remove: ${_name(route)}');
}
