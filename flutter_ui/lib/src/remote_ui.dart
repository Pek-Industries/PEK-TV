import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';
import 'remote_client.dart';
import 'remote_host.dart';
import 'remote_pairing.dart' show RemoteProtocol;
import 'tokens.dart';
import 'widgets.dart';

/// Settings > Remote. On a TV it is the place to pair phones; on a phone or tablet it is the remote itself.
class RemotePage extends StatelessWidget {
  const RemotePage({super.key, required this.padding});
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => context.pek.tvDevice ? _HostPage(padding: padding) : _PhonePage(padding: padding);
}

// ==================================================================================================== TV: pair phones

class _HostPage extends StatefulWidget {
  const _HostPage({required this.padding});
  final EdgeInsets padding;
  @override
  State<_HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<_HostPage> {
  final _host = RemoteHost.instance;
  Timer? _clock;
  late final Future<String> _addr = RemoteHost.localAddress();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _host.pairing.isOpen) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _host.closePairing(); // a code is only good while this screen is open
    super.dispose();
  }

  Future<void> _remove(PairedDeviceView d) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: const Text('That phone will have to pair again with a new code.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (yes == true) await _host.revoke(d.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return ListenableBuilder(
      listenable: _host,
      builder: (context, _) {
        final pin = _host.pairing.pin;
        final left = _host.pairing.timeLeft;
        final devices = [for (final d in _host.pairing.devices) PairedDeviceView(d.id, d.name)];
        return ListView(padding: widget.padding, children: [
          if (p.sidebar) const Heading('Remote'),
          Text(
            _host.running
                ? 'Phones on the same Wi-Fi or network can use this TV as a remote and keyboard. Each phone pairs once with a code.'
                : 'The phone remote is off. Nothing on this TV listens for phones.',
            style: TextStyle(color: t.textMuted, fontSize: 1.0 * rem),
          ),
          if (_host.error.isNotEmpty) Padding(padding: EdgeInsets.only(top: 0.5 * rem), child: Text(_host.error, style: const TextStyle(color: Colors.redAccent))),
          SizedBox(height: 0.8 * rem),
          Wrap(spacing: 8, runSpacing: 8, children: [
            PekButton(label: _host.running ? 'Turn off' : 'Turn on', shrink: true, onTap: () => _host.setEnabled(!_host.running)),
            if (_host.running && pin == null) PekButton(label: 'Pair a phone', primary: true, autofocus: true, shrink: true, onTap: _host.openPairing),
            if (pin != null) PekButton(label: 'Cancel pairing', shrink: true, onTap: _host.closePairing),
          ]),
          if (pin != null) ...[
            SizedBox(height: 1.2 * rem),
            Text('On your phone open PEK TV > Settings > Remote, pick this TV and enter:', style: TextStyle(color: t.textMuted, fontSize: 1.0 * rem)),
            SizedBox(height: 0.4 * rem),
            Text('${pin.substring(0, 3)} ${pin.substring(3)}', style: TextStyle(fontSize: 3.2 * rem, fontWeight: FontWeight.w800, letterSpacing: 0.3 * rem, color: t.accent, fontFeatures: const [FontFeature.tabularFigures()])),
            Text('Works for ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')} more, once.', style: TextStyle(color: t.textMuted, fontSize: 0.9 * rem)),
          ],
          if (_host.running) ...[
            SizedBox(height: 1.0 * rem),
            FutureBuilder<String>(
              future: _addr,
              builder: (c, s) => Text(
                (s.data ?? '').isEmpty ? '' : "This TV's address: ${s.data}  (if the phone cannot find it, type this)",
                style: TextStyle(color: t.textMuted, fontSize: 0.9 * rem),
              ),
            ),
            if (_host.connected > 0) Text('${_host.connected} phone${_host.connected == 1 ? '' : 's'} connected now.', style: TextStyle(color: t.textMuted, fontSize: 0.9 * rem)),
          ],
          SizedBox(height: 1.2 * rem),
          if (devices.isNotEmpty) Text('Paired phones', style: TextStyle(fontSize: 1.1 * rem, fontWeight: FontWeight.w700)),
          for (final d in devices) ListRow(title: d.name, subtitle: 'Select to remove', onTap: () => _remove(d)),
        ]);
      },
    );
  }
}

class PairedDeviceView {
  const PairedDeviceView(this.id, this.name);
  final String id;
  final String name;
}

// ==================================================================================================== phone: the remote

class _PhonePage extends StatefulWidget {
  const _PhonePage({required this.padding});
  final EdgeInsets padding;
  @override
  State<_PhonePage> createState() => _PhonePageState();
}

class _PhonePageState extends State<_PhonePage> {
  final _c = RemoteClient.instance;
  final _pin = TextEditingController();
  final _addr = TextEditingController();
  final _typed = TextEditingController();
  int _fid = -1;

  @override
  void initState() {
    super.initState();
    _c.load().then((_) => _c.autoConnect());
  }

  @override
  void dispose() {
    _pin.dispose();
    _addr.dispose();
    _typed.dispose();
    _c.disconnect(); // the connection only lives while this screen is open
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final body = switch (_c.state) {
          RemoteState.ready => _remote(context),
          RemoteState.needPair => _pairing(context),
          RemoteState.connecting => [Padding(padding: const EdgeInsets.all(32), child: Center(child: Column(children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text('Connecting\u2026', style: TextStyle(color: context.pek.tokens.textMuted))])))],
          _ => _picker(context),
        };
        return ListView(padding: widget.padding, children: [if (context.pek.sidebar) const Heading('Remote'), ...body]);
      },
    );
  }

  // ---- choose a TV
  List<Widget> _picker(BuildContext context) {
    final t = context.pek.tokens;
    final fresh = [for (final f in _c.found) if (!_c.saved.any((s) => s.id == f.id)) f];
    return [
      if (_c.error.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_c.error, style: const TextStyle(color: Colors.redAccent))),
      if (_c.state == RemoteState.lost) Padding(padding: const EdgeInsets.only(bottom: 8), child: PekButton(label: 'Try again', primary: true, onTap: _c.retryNow)),
      Text('Use this phone as a remote and keyboard for PEK TV. On the TV open Settings > Remote > Pair a phone.', style: TextStyle(color: t.textMuted)),
      const SizedBox(height: 12),
      if (_c.saved.isNotEmpty) Text('Your TVs', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      for (final s in _c.saved)
        ListRow(
          title: s.name,
          subtitle: s.host,
          onTap: () => _c.connect(s.host, s.port, tvId: s.id),
          onLongPress: () => _c.forget(s),
        ),
      if (fresh.isNotEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Found on this network', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
      for (final f in fresh) ListRow(title: f.name, subtitle: f.host, onTap: () => _c.connect(f.host, f.port, tvId: f.id)),
      const SizedBox(height: 8),
      PekButton(label: _c.searching ? 'Searching\u2026' : 'Search for TVs', onTap: _c.searching ? null : _c.search),
      const SizedBox(height: 16),
      Text("Can't find it? Type the TV's address (shown on the TV):", style: TextStyle(color: t.textMuted)),
      const SizedBox(height: 6),
      TextField(controller: _addr, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: '192.168.1.20', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      PekButton(
        label: 'Connect',
        onTap: () {
          final a = _addr.text.trim();
          if (a.isNotEmpty) _c.connect(a, RemoteProtocol.wsPort);
        },
      ),
    ];
  }

  // ---- the code from the TV
  List<Widget> _pairing(BuildContext context) {
    final t = context.pek.tokens;
    return [
      Text('Pair with ${_c.tvName}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
      const SizedBox(height: 6),
      Text('On the TV open Settings > Remote > Pair a phone, then type the 6-digit code it shows.', style: TextStyle(color: t.textMuted)),
      const SizedBox(height: 12),
      TextField(
        controller: _pin,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
        style: const TextStyle(fontSize: 28, letterSpacing: 6, fontWeight: FontWeight.w700),
        textAlign: TextAlign.center,
        decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '000000'),
        onSubmitted: (v) => _c.pair(v),
      ),
      if (_c.error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_c.error, style: const TextStyle(color: Colors.redAccent))),
      const SizedBox(height: 12),
      PekButton(label: 'Pair', primary: true, onTap: () => _c.pair(_pin.text)),
      const SizedBox(height: 8),
      PekButton(label: 'Choose another TV', onTap: _c.disconnect),
    ];
  }

  // ---- the remote
  List<Widget> _remote(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final w = math.min(MediaQuery.sizeOf(context).width - 32, 300.0);

    // The TV's text box changed (another one got the focus): start the phone's box from what the TV has.
    if (_c.field.on && _c.field.fid != _fid) {
      _fid = _c.field.fid;
      _typed.text = _c.field.text;
      _typed.selection = TextSelection.collapsed(offset: _typed.text.length);
    }
    if (!_c.field.on) _fid = -1;

    String clock(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

    return [
      Row(children: [
        Icon(Icons.tv, color: t.accent),
        const SizedBox(width: 8),
        Expanded(child: Text(_c.tvName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16), overflow: TextOverflow.ellipsis)),
        TextButton(onPressed: _c.disconnect, child: const Text('Change TV')),
      ]),
      const SizedBox(height: 8),
      Center(child: _DPad(size: w, onKey: _c.key)),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _RoundBtn(icon: Icons.arrow_back, label: 'Back', onTap: () => _c.nav('back')),
        _RoundBtn(icon: Icons.home_outlined, label: 'Home', onTap: () => _c.nav('home')),
        _RoundBtn(icon: Icons.menu, label: 'Menu', onTap: () => _c.key('menu')),
      ]),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _RoundBtn(icon: Icons.replay_10, label: '-10 s', repeat: true, onTap: () => _c.seek(-10)),
        _RoundBtn(icon: _c.playing ? Icons.pause : Icons.play_arrow, label: _c.playing ? 'Pause' : 'Play', big: true, onTap: _c.playPause),
        _RoundBtn(icon: Icons.forward_10, label: '+10 s', repeat: true, onTap: () => _c.seek(10)),
      ]),
      if (_c.dur > 0) ...[
        const SizedBox(height: 8),
        LinearProgressIndicator(value: (_c.pos / _c.dur).clamp(0.0, 1.0), minHeight: 4, color: t.accent, backgroundColor: t.border),
        Padding(padding: const EdgeInsets.only(top: 4), child: Text('${clock(_c.pos)} / ${clock(_c.dur)}', style: TextStyle(color: t.textMuted, fontSize: 12))),
      ],
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _RoundBtn(icon: Icons.volume_down, label: 'Vol -', repeat: true, onTap: () => _c.volume(-1)),
        _RoundBtn(icon: Icons.volume_off, label: 'Mute', onTap: () => _c.volume(0)),
        _RoundBtn(icon: Icons.volume_up, label: 'Vol +', repeat: true, onTap: () => _c.volume(1)),
      ]),
      const SizedBox(height: 20),
      if (_c.field.on)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: t.accent)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Typing on the TV', style: TextStyle(color: t.textMuted, fontSize: 12)),
            const SizedBox(height: 6),
            TextField(
              controller: _typed,
              autofocus: true,
              obscureText: _c.field.hide,
              minLines: 1,
              maxLines: _c.field.multi ? 4 : 1,
              textInputAction: _c.field.multi ? TextInputAction.newline : TextInputAction.done,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              onChanged: _c.text,
              onSubmitted: (_) => _c.submit(),
            ),
            const SizedBox(height: 8),
            PekButton(label: 'Done', primary: true, compact: true, onTap: _c.submit),
          ]),
        )
      else
        Text('To type, select a text box on the TV. A keyboard box appears here.', style: TextStyle(color: t.textMuted, fontSize: 12), textAlign: TextAlign.center),
      const SizedBox(height: 24),
    ];
  }
}

// ---- buttons ------------------------------------------------------------------------------------------------

/// Fires on touch, and keeps firing while held when [repeat] is set (about as fast as KeyGuard lets a held arrow go).
///
/// Shows the press: the button shrinks a little and a soft round highlight flashes over it, on top of the buzz. A quick tap is
/// kept on screen for a moment ([_minShown]) so it is seen, a held button stays pressed until you let go.
class _Hold extends StatefulWidget {
  const _Hold({required this.onFire, required this.child, this.repeat = true});
  final VoidCallback onFire;
  final Widget child;
  final bool repeat;
  @override
  State<_Hold> createState() => _HoldState();
}

class _HoldState extends State<_Hold> {
  static const _minShown = Duration(milliseconds: 130);
  Timer? _t;
  Timer? _release;
  bool _pressed = false;
  DateTime _downAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _show() {
    _release?.cancel();
    _downAt = DateTime.now();
    if (!_pressed) setState(() => _pressed = true);
  }

  void _hide() {
    _release?.cancel();
    final left = _minShown - DateTime.now().difference(_downAt);
    void off() {
      if (mounted && _pressed) setState(() => _pressed = false);
    }

    if (left <= Duration.zero) {
      off();
    } else {
      _release = Timer(left, off);
    }
  }

  void _fire() {
    HapticFeedback.selectionClick();
    widget.onFire();
  }

  void _down() {
    _show();
    _fire();
    if (!widget.repeat) return;
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 400), () {
      _t = Timer.periodic(const Duration(milliseconds: 180), (_) => _fire());
    });
  }

  void _up() {
    _t?.cancel();
    _t = null;
    _hide();
  }

  @override
  void dispose() {
    _t?.cancel();
    _release?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glow = context.pek.tokens.text.withAlpha(64);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      // The Listener stays outside the scale, so the touch area does not shrink while you press.
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: Stack(alignment: Alignment.center, children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _pressed ? 1 : 0,
                duration: const Duration(milliseconds: 90),
                child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: glow)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.label, required this.onTap, this.big = false, this.repeat = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool big;
  final bool repeat;

  @override
  Widget build(BuildContext context) {
    final t = context.pek.tokens;
    final d = big ? 72.0 : 56.0;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _Hold(
        onFire: onTap,
        repeat: repeat,
        child: Semantics(
          button: true,
          label: label,
          child: Container(
            width: d,
            height: d,
            decoration: BoxDecoration(shape: BoxShape.circle, color: big ? t.accent : t.surface, border: Border.all(color: t.border)),
            child: Icon(icon, size: big ? 36 : 28, color: big ? t.bg : t.text),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(label, style: TextStyle(color: t.textMuted, fontSize: 11)),
    ]);
  }
}

class _DPad extends StatelessWidget {
  const _DPad({required this.size, required this.onKey});
  final double size;
  final void Function(String key) onKey;

  @override
  Widget build(BuildContext context) {
    final t = context.pek.tokens;
    final zone = size * 0.3;
    Widget arrow(String k, IconData icon, Alignment a) => Align(
          alignment: a,
          child: _Hold(
            onFire: () => onKey(k),
            child: Semantics(button: true, label: k, child: SizedBox(width: zone, height: zone, child: Icon(icon, size: size * 0.16, color: t.text))),
          ),
        );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: t.surface, border: Border.all(color: t.border, width: 2)),
      child: Stack(children: [
        arrow('up', Icons.keyboard_arrow_up, Alignment.topCenter),
        arrow('down', Icons.keyboard_arrow_down, Alignment.bottomCenter),
        arrow('left', Icons.keyboard_arrow_left, Alignment.centerLeft),
        arrow('right', Icons.keyboard_arrow_right, Alignment.centerRight),
        Align(
          alignment: Alignment.center,
          child: _Hold(
            repeat: false,
            onFire: () => onKey('ok'),
            child: Semantics(
              button: true,
              label: 'OK',
              child: Container(
                width: size * 0.34,
                height: size * 0.34,
                decoration: BoxDecoration(shape: BoxShape.circle, color: t.accent),
                alignment: Alignment.center,
                child: Text('OK', style: TextStyle(color: t.bg, fontWeight: FontWeight.w800, fontSize: size * 0.09)),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
