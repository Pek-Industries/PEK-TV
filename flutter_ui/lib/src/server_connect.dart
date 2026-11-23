import 'dart:async';

import 'package:flutter/material.dart';

import 'cloud.dart';
import 'common.dart';
import 'fields.dart' show PekField;
import 'l10n.dart';
import 'server_target.dart';
import 'tokens.dart';
import 'widgets.dart';

/// Settings > Library, at the top: where the library is (this device, or a paired PEK Server) and the buttons to change it.
class LibraryServerSection extends StatefulWidget {
  const LibraryServerSection({super.key});
  @override
  State<LibraryServerSection> createState() => _LibraryServerSectionState();
}

class _LibraryServerSectionState extends State<LibraryServerSection> {
  bool _checking = false;
  FoundServer? _info; // version / "a newer version is out" from GET /api/server/info

  @override
  void initState() {
    super.initState();
    if (ServerTarget.remote) unawaited(_recheck());
  }

  Future<void> _recheck() async {
    setState(() => _checking = true);
    await ServerTarget.check();
    FoundServer? info;
    if (ServerTarget.reachable.value) {
      try {
        info = await ServerTarget.probe(ServerTarget.address);
      } catch (_) {}
    }
    if (mounted) setState(() { _checking = false; _info = info; });
  }

  /// The server only tells us a newer version is out; updating is the owner's choice, done on the server itself.
  Future<void> _howToUpdate(FoundServer info) async {
    final p = context.pek;
    final String intro;
    final List<String> commands;
    String extra = '';
    switch (info.platform) {
      case 'windows':
        intro = 'On the server PC, double-click "Update PEK Server.bat" in the PEK Server folder.'.tr;
        commands = const [];
      case 'termux':
        intro = 'On the phone that runs the server, open Termux and run:'.tr;
        commands = const ['pek-server --update'];
      case 'docker':
        intro = 'Rebuild the image, then start it again:'.tr;
        commands = const ['docker compose build --pull', 'docker compose up -d'];
      default:
        intro = 'On the server, run:'.tr;
        commands = const ['sudo /opt/pek-server/pek-server --update'];
        extra = 'If you start PEK Server yourself instead of as a service, run  pek-server --update  in its folder, then restart it.'.tr;
    }
    await showDialog<void>(
      context: context,
      barrierColor: p.tokens.overlay,
      builder: (c) => AlertDialog(
        backgroundColor: p.tokens.glassStrong,
        title: Text('Update PEK Server'.tr),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('PEK Server {version} is available (this one runs {current}).'.trp({'version': info.update, 'current': info.version})),
          SizedBox(height: p.rem),
          Text(intro),
          for (final cmd in commands) ...[
            SizedBox(height: 0.5 * p.rem),
            SelectableText(cmd, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
          ],
          if (extra.isNotEmpty) ...[SizedBox(height: p.rem), Text(extra, style: TextStyle(color: p.tokens.textMuted))],
          SizedBox(height: p.rem),
          Text('PEK Server never updates by itself. Your library, accounts and settings are kept.'.tr, style: TextStyle(color: p.tokens.textMuted)),
        ]),
        actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(c), child: Text('Done'.tr))],
      ),
    );
  }

  Future<void> _connect() => openServerConnect(context);

  Future<void> _useDevice() async {
    final p = context.pek;
    final yes = await showDialog<bool>(
      context: context,
      barrierColor: p.tokens.overlay,
      builder: (c) => AlertDialog(
        backgroundColor: p.tokens.glassStrong,
        title: Text('Use the library on this device?'.tr),
        content: Text('PEK TV stops using {name}. Nothing is deleted on the server; connecting again later needs a new pairing code.'.trp({'name': ServerTarget.name})),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(c, false), child: Text('Cancel'.tr)),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text('Use this device'.tr)),
        ],
      ),
    );
    if (yes != true) return;
    await ServerTarget.useThisDevice();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst); // the app shell is rebuilt for the other library
  }

  Future<void> _pairAnother() async {
    String? code;
    String error = '';
    try {
      code = await ServerTarget.newCode();
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    final p = context.pek;
    final shown = code; // a final copy for the dialog below
    await showDialog<void>(
      context: context,
      barrierColor: p.tokens.overlay,
      builder: (c) => AlertDialog(
        backgroundColor: p.tokens.glassStrong,
        title: Text('Pair another device'.tr),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (shown != null) ...[
            Text('On the other TV or phone open Settings > Library > Connect to a server, pick {name} and type:'.trp({'name': ServerTarget.name})),
            SizedBox(height: p.rem),
            Center(child: SelectableText('${shown.substring(0, 3)} ${shown.substring(3)}', style: TextStyle(fontSize: 2.4 * p.rem, fontWeight: FontWeight.w800, letterSpacing: 4))),
            SizedBox(height: 0.5 * p.rem),
            Text('Works for 10 minutes, for one device.'.tr, style: TextStyle(color: p.tokens.textMuted)),
          ] else
            Text('Could not get a code: {error}'.trp({'error': error})),
        ]),
        actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(c), child: Text('Done'.tr))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    return ListenableBuilder(
      listenable: Listenable.merge([ServerTarget.changes, ServerTarget.reachable, ServerTarget.needsPairing]),
      builder: (context, _) {
        if (!ServerTarget.remote) {
          return Section(
            title: 'Library server'.tr,
            hint: 'Your library is on this device. Have a PEK Server at home? Connect to it to watch its library here.'.tr,
            children: [
              Wrap(spacing: 8, runSpacing: 8, children: [PekButton(label: 'Connect to a server'.tr, onTap: _connect)]),
            ],
          );
        }
        final String status;
        if (_checking) {
          status = 'Checking…'.tr;
        } else if (ServerTarget.needsPairing.value) {
          status = 'The server no longer accepts this device (its key was changed). Pair it again.'.tr;
        } else if (!ServerTarget.reachable.value) {
          status = 'Not reachable right now. Showing the library saved on this device.'.tr;
        } else {
          status = 'Connected'.tr;
        }
        final info = _info;
        final update = info != null && info.update.isNotEmpty && !_checking ? info : null;
        return Section(
          title: 'Library server'.tr,
          hint: 'Movies, shows and music come from your PEK Server. Plugins and skins stay on this device.'.tr,
          children: [
            ListRow(
              leading: Icon(Icons.dns_outlined, color: p.tokens.accent),
              title: ServerTarget.name,
              subtitle: '${ServerTarget.address} · $status',
              onTap: _recheck,
            ),
            if (update != null)
              ListRow(
                leading: Icon(Icons.system_update_alt, color: p.tokens.accent),
                title: 'PEK Server {version} is available (this one runs {current}).'.trp({'version': update.update, 'current': update.version}),
                subtitle: 'How to update'.tr,
                onTap: () => _howToUpdate(update),
              ),
            SizedBox(height: 0.5 * rem),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (ServerTarget.needsPairing.value) PekButton(label: 'Pair again'.tr, primary: true, onTap: _connect),
              if (!ServerTarget.needsPairing.value && ServerTarget.reachable.value) PekButton(label: 'Pair another device'.tr, onTap: _pairAnother),
              PekButton(label: 'Change server'.tr, onTap: _connect),
              PekButton(label: 'Use this device instead'.tr, onTap: _useDevice),
            ]),
          ],
        );
      },
    );
  }
}

/// Opens the Connect screen. Returns true when a server was paired (the app shell is then rebuilt and the stack popped).
Future<bool> openServerConnect(BuildContext context, {bool popToRoot = true}) async {
  final ok = await Navigator.push<bool>(
    context,
    MaterialPageRoute<bool>(builder: (_) => SubScreen(title: 'Connect to a server'.tr, body: const ServerConnectPage())),
  );
  if (ok == true && popToRoot && context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  return ok == true;
}

/// Lists the PEK Servers that answer on this network, or takes a typed address, then opens the pairing step.
class ServerConnectPage extends StatefulWidget {
  const ServerConnectPage({super.key});
  @override
  State<ServerConnectPage> createState() => _ServerConnectPageState();
}

class _ServerConnectPageState extends State<ServerConnectPage> {
  List<FoundServer> _found = const [];
  bool _searching = false;
  final _address = TextEditingController();
  String _error = '';
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final list = await ServerTarget.discover();
    if (!mounted) return;
    setState(() {
      _found = list;
      _searching = false;
    });
  }

  Future<void> _pick(FoundServer s) async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute<bool>(builder: (_) => SubScreen(title: s.name, body: ServerPairPage(server: s))));
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  Future<void> _typed() async {
    final a = ServerTarget.normalize(_address.text);
    if (a.isEmpty) {
      setState(() => _error = 'Type the server\'s address, for example 192.168.1.20 or 192.168.1.20:8080.'.tr);
      return;
    }
    setState(() {
      _probing = true;
      _error = '';
    });
    try {
      final s = await ServerTarget.probe(a);
      if (!mounted) return;
      setState(() => _probing = false);
      await _pick(s);
    } on ServerError catch (e) {
      if (mounted) {
        setState(() {
          _probing = false;
          _error = e.message.tr;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return ListView(padding: context.pek.pagePad, children: [
      Section(
        title: 'On your network'.tr,
        hint: 'PEK Servers on the same Wi-Fi or network as this device.'.tr,
        children: [
          if (_searching && _found.isEmpty)
            Padding(padding: EdgeInsets.symmetric(vertical: 0.75 * rem), child: Text('Looking…'.tr, style: TextStyle(color: t.textMuted)))
          else if (_found.isEmpty)
            PekCard(
              title: 'No server found'.tr,
              subtitle: 'Check that PEK Server is running and this device is on the same network. A server in Docker or behind a router is not found this way: type its address below.'.tr,
            ),
          for (final (i, s) in _found.indexed)
            ListRow(
              autofocus: i == 0,
              leading: Icon(Icons.dns_outlined, color: t.accent),
              title: s.name,
              subtitle: [Uri.tryParse(s.address)?.authority ?? s.address, if (s.version.isNotEmpty) 'v${s.version}', if (s.id == ServerTarget.id && ServerTarget.remote) 'in use'.tr].join(' · '),
              trailing: Icon(Icons.chevron_right, color: t.textMuted),
              onTap: () => _pick(s),
            ),
          SizedBox(height: 0.5 * rem),
          Wrap(spacing: 8, runSpacing: 8, children: [PekButton(label: _searching ? 'Searching…'.tr : 'Search again'.tr, onTap: _searching ? null : _search)]),
        ],
      ),
      const ThinDivider(),
      Section(
        title: 'Type an address'.tr,
        hint: 'The address PEK Server printed when it started (also in pairing.txt). From outside your home use Tailscale or an https address.'.tr,
        children: [
          PekField(label: 'Server address'.tr, hint: '192.168.1.20:8080', controller: _address, keyboardType: TextInputType.url, onSubmitted: _typed),
          if (_error.isNotEmpty) Padding(padding: EdgeInsets.only(top: 0.5 * rem), child: Text(_error, style: const TextStyle(color: Colors.redAccent))),
          SizedBox(height: 0.75 * rem),
          Wrap(spacing: 8, runSpacing: 8, children: [PekButton(label: _probing ? 'Checking…'.tr : 'Next'.tr, primary: true, onTap: _probing ? null : _typed)]),
        ],
      ),
    ]);
  }
}

/// Step two: the code from the server (or its access key) for one server.
class ServerPairPage extends StatefulWidget {
  const ServerPairPage({super.key, required this.server});
  final FoundServer server;
  @override
  State<ServerPairPage> createState() => _ServerPairPageState();
}

class _ServerPairPageState extends State<ServerPairPage> {
  final _code = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String _error = '';
  // A server with accounts: signing in also pairs this device (the server hands out its key with the session), so that comes first.
  late bool _signIn = widget.server.accounts;

  @override
  void dispose() {
    _code.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _signInNow() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Type your username and password.'.tr);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final s = widget.server;
    final r = await Cloud.serverLogin(s.address, _user.text, _pass.text);
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _busy = false;
        _error = switch (r.error) {
          'bad_credentials' => 'Wrong username or password.'.tr,
          'rate_limited' => 'Too many wrong passwords. Wait a few minutes and try again.'.tr,
          'offline' => 'Could not reach the server. Try again.'.tr,
          _ => 'Could not sign in ({code}).'.trp({'code': r.error}),
        };
      });
      return;
    }
    await ServerTarget.use(s, '${r.body['key']}');
    await Cloud.adoptServerSession(r.body);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _connect() async {
    final typed = _code.text.trim();
    final digits = typed.replaceAll(RegExp(r'[\s-]'), '');
    final isCode = RegExp(r'^\d{6}$').hasMatch(digits);
    final isKey = RegExp(r'^[A-Za-z0-9]{24,}$').hasMatch(typed);
    if (!isCode && !isKey) {
      setState(() => _error = 'Type the 6-digit code the server shows (or its access key).'.tr);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final s = widget.server;
      final String key;
      if (isCode) {
        key = await ServerTarget.pair(s.address, digits);
      } else {
        await ServerTarget.checkKey(s.address, typed);
        key = typed;
      }
      await ServerTarget.use(s, key);
      if (mounted) Navigator.pop(context, true);
    } on ServerError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message.tr;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final s = widget.server;
    final insecure = ServerTarget.insecure(s.address);
    return ListView(padding: context.pek.pagePad, children: [
      Section(
        title: (_signIn ? 'Sign in to {name}' : 'Pair with {name}').trp({'name': s.name}),
        hint: _signIn
            ? 'Use the account the server owner made for you. Signing in also connects this device, and your history and resume points sync through the server.'.tr
            : 'PEK Server shows a 6-digit pairing code when it starts. For a new one run  pek-server --pair  on the server (Windows: "Pair a device.bat"), or use "Pair another device" on a TV or phone that is already connected.'.tr,
        children: [
          Text(s.address, style: TextStyle(color: t.textMuted, fontSize: 0.9 * rem)),
          SizedBox(height: 0.75 * rem),
          if (insecure)
            Padding(
              padding: EdgeInsets.only(bottom: 0.75 * rem),
              child: PekCard(
                title: 'This connection is not private'.tr,
                subtitle: 'This looks like an internet address without https: the key and what you watch travel unencrypted. Use Tailscale, or put the server behind a reverse proxy with https.'.tr,
              ),
            ),
          if (_signIn) ...[
            PekField(label: 'Username or email'.tr, controller: _user, autofocus: true, keyboardType: TextInputType.text),
            PekField(label: 'Password'.tr, controller: _pass, obscure: true, onSubmitted: _signInNow),
          ] else
            PekField(
              label: 'Pairing code'.tr,
              hint: '123 456',
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.visiblePassword, // digits, or a pasted key; no autocorrect
              onSubmitted: _connect,
            ),
          if (_error.isNotEmpty) Padding(padding: EdgeInsets.only(top: 0.5 * rem), child: Text(_error, style: const TextStyle(color: Colors.redAccent))),
          SizedBox(height: 0.75 * rem),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (_signIn)
              PekButton(label: _busy ? 'Signing in…'.tr : 'Sign in'.tr, primary: true, onTap: _busy ? null : _signInNow)
            else
              PekButton(label: _busy ? 'Connecting…'.tr : 'Connect'.tr, primary: true, onTap: _busy ? null : _connect),
            if (s.accounts)
              PekButton(
                label: _signIn ? 'Use a pairing code instead'.tr : 'Sign in with an account instead'.tr,
                onTap: _busy
                    ? null
                    : () => setState(() {
                          _signIn = !_signIn;
                          _error = '';
                        }),
              ),
          ]),
        ],
      ),
    ]);
  }
}

/// First launch: where is the library? This device (the usual) or a PEK Server at home. Picking the server opens the Connect
/// screen; backing out of it leaves the question open.
class ServerChoiceScreen extends StatefulWidget {
  const ServerChoiceScreen({super.key, required this.onDone});
  final VoidCallback onDone;
  @override
  State<ServerChoiceScreen> createState() => _ServerChoiceScreenState();
}

class _ServerChoiceScreenState extends State<ServerChoiceScreen> {
  Future<void> _server() async {
    final ok = await openServerConnect(context, popToRoot: false);
    if (ok && mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final wide = p.isTv || p.size.width > p.size.height;
    Widget card(IconData icon, String title, String text, VoidCallback onTap, {bool autofocus = false}) => PekFocusable(
          autofocus: autofocus,
          onTap: onTap,
          radius: 18,
          background: t.surface,
          borderColor: t.border,
          padding: EdgeInsets.all(1.25 * rem),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 2.4 * rem, color: t.accent),
            SizedBox(height: 0.75 * rem),
            Text(title.tr, style: TextStyle(fontSize: 1.3 * rem, fontWeight: FontWeight.w800)),
            SizedBox(height: 0.25 * rem),
            Text(text.tr, style: TextStyle(color: t.textMuted, fontSize: 0.9 * rem, height: 1.35)),
          ]),
        );
    final cards = [
      card(Icons.tv, 'On this device', 'Add folders and network shares right here. The usual choice.', widget.onDone, autofocus: true),
      card(Icons.dns_outlined, 'On my PEK Server', 'You run PEK Server on a PC, NAS or Docker at home. Pair with it and watch its library here.', _server),
    ];
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: p.safeX).add(EdgeInsets.all(rem)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Where is your library?'.tr, style: TextStyle(fontSize: 1.7 * rem, fontWeight: FontWeight.w800, height: 1.15)),
            SizedBox(height: 0.5 * rem),
            Text('You can change this any time in Settings, under Library.'.tr, style: TextStyle(color: t.textMuted, fontSize: rem, height: 1.4)),
            SizedBox(height: 1.25 * rem),
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: cards[0]), SizedBox(width: rem), Expanded(child: cards[1])])
            else
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [cards[0], SizedBox(height: 0.75 * rem), cards[1]]),
          ]),
        ),
      ),
    );
  }
}
