import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'cloud.dart';
import 'common.dart';
import 'discord.dart';
import 'settings_extra.dart' show ToggleRow;
import 'store.dart';
import 'tokens.dart';
import 'widgets.dart';

/// Settings > Account > Discord: link a Discord account so the profile shows what is playing ("Watching ..."). A phone gets a
/// button that opens Discord's approval page; a TV gets a QR code to scan with the phone. Both use the PekButton / tokens, so
/// they follow the skin. See discord.dart and DISCORD.md.
class DiscordSection extends StatelessWidget {
  const DiscordSection({super.key});

  Future<void> _link(BuildContext context) async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const DiscordLinkScreen()));
  }

  Future<void> _unlink(BuildContext context) async {
    final p = context.pek;
    final yes = await showDialog<bool>(
      context: context,
      barrierColor: p.tokens.overlay,
      builder: (c) => AlertDialog(
        backgroundColor: p.tokens.glassStrong,
        title: const Text('Unlink Discord?'),
        content: const Text('PEK TV stops showing what you watch on this profile. You can link again at any time.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Unlink')),
        ],
      ),
    );
    if (yes == true) await DiscordPresence.unlink();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([DiscordPresence.changed, Cloud.changes]),
      builder: (context, _) => ValueListenableBuilder<String>(
        valueListenable: Store.profile,
        builder: (context, _, __) {
          final known = DiscordPresence.knownAvailable;
          if (known != null) return _content(context, known);
          return FutureBuilder<bool>(future: DiscordPresence.available(), builder: (context, snap) => _content(context, snap.data));
        },
      ),
    );
  }

  /// [ready] = whether this build has Discord support (null while that is being found out).
  Widget _content(BuildContext context, bool? ready) {
    final p = context.pek;
    final t = p.tokens;
    final tv = p.isTv;
    const hint = 'Shows what you are watching on your Discord profile, like Spotify does. Each profile links its own Discord account. Only the title (or just \u201cPEK TV\u201d) is shared, and nothing is shared while it is off.';
    if (ready == false) {
      return Section(title: 'Discord', hint: hint, children: [
        Text('This version of PEK TV was built without Discord support.', style: TextStyle(color: t.textMuted, fontSize: 0.9 * p.rem)),
      ]);
    }
    if (!Cloud.linked) {
      // Discord can only be linked from a signed-in PEK account (the cloud refuses the link otherwise).
      return Section(title: 'Discord', hint: hint, children: [
        Text('Sign in to your PEK account (Settings > Account) to link Discord.', style: TextStyle(color: t.textMuted, fontSize: 0.9 * p.rem)),
      ]);
    }
    if (!DiscordPresence.linked) {
      return Section(title: 'Discord', hint: hint, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: PekButton(
            primary: true,
            label: tv ? 'Link Discord with a QR code' : 'Link Discord',
            leading: Icon(tv ? Icons.qr_code_2 : Icons.link, size: 1.1 * p.rem, color: t.bg),
            onTap: ready == null ? null : () => _link(context),
          ),
        ),
      ]);
    }
    final showing = DiscordPresence.showing;
    return Section(title: 'Discord', hint: hint, children: [
      ToggleRow(
        title: 'Show what I am watching',
        subtitle: showing ? 'On: your profile shows what plays' : 'Off: nothing is shared',
        on: showing,
        onTap: () => DiscordPresence.setShowing(!showing),
      ),
      ToggleRow(
        title: 'Show titles',
        subtitle: DiscordPresence.showTitles ? 'Your profile shows the movie or show name' : 'Your profile only says \u201cWatching on PEK TV\u201d',
        on: DiscordPresence.showTitles,
        onTap: () => DiscordPresence.setShowTitles(!DiscordPresence.showTitles),
      ),
      SizedBox(height: 0.5 * p.rem),
      Align(alignment: Alignment.centerLeft, child: PekButton(label: 'Unlink Discord', onTap: () => _unlink(context))),
    ]);
  }
}

/// The linking screen. On a TV: the QR code (white with a quiet border so a phone reads it on any skin). On a phone: the approval
/// page opens by itself, with a button to open it again. Either way this screen asks the cloud every few seconds and closes as
/// soon as Discord is approved. A link lasts 10 minutes; a new one is made by itself.
class DiscordLinkScreen extends StatefulWidget {
  const DiscordLinkScreen({super.key});
  @override
  State<DiscordLinkScreen> createState() => _DiscordLinkScreenState();
}

class _DiscordLinkScreenState extends State<DiscordLinkScreen> {
  DiscordLinkSession? _s;
  String _error = '';
  bool _starting = false;
  bool _polling = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting) return;
    _starting = true;
    _timer?.cancel();
    if (mounted) setState(() => _error = '');
    final (s, err) = await DiscordPresence.startLink();
    _starting = false;
    if (!mounted) return;
    if (s == null) {
      setState(() {
        _s = null;
        _error = Cloud.errorText(err);
      });
      return;
    }
    setState(() => _s = s);
    _timer = Timer.periodic(Duration(seconds: s.interval), (_) => _tick());
    if (!context.pek.isTv) unawaited(DiscordPresence.openUrl(s.url)); // a phone goes straight to Discord's approval page
  }

  Future<void> _tick() async {
    final s = _s;
    if (!mounted || s == null || _starting || _polling) return;
    if (DateTime.now().millisecondsSinceEpoch >= s.expiresAt) {
      await _start(); // the link ran out: make a fresh one
      return;
    }
    _polling = true;
    final r = await DiscordPresence.pollLink(s);
    _polling = false;
    if (!mounted) return;
    if (r == 'done') {
      Navigator.of(context).pop();
      return;
    }
    if (r == 'expired') {
      await _start();
      return;
    }
    if (r == 'signed_out') {
      _timer?.cancel();
      Navigator.of(context).pop(); // the PEK session is gone: back to Settings, which says to sign in
      return;
    }
    if (mounted) setState(() {}); // refreshes the countdown
  }

  String _left(DiscordLinkSession s) {
    final secs = math.max(0, ((s.expiresAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil());
    return '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final s = _s;
    final tv = p.isTv;

    return SubScreen(
      title: 'Link Discord',
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 46 * rem;
        final qrSize = math.min(wide ? 15.0 * rem : 13.0 * rem, math.max(8.0 * rem, box.maxWidth - 2 * rem));

        final steps = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (tv) ...[
            Text('1. Scan the QR code with your phone.', style: TextStyle(color: t.textMuted, fontSize: 1.0 * rem)),
            SizedBox(height: 0.5 * rem),
            Text('2. Sign in to Discord if it asks, then tap Authorize.', style: TextStyle(color: t.textMuted, fontSize: 1.0 * rem)),
            SizedBox(height: 0.5 * rem),
            Text('3. This screen closes by itself once Discord is linked.', style: TextStyle(color: t.textMuted, fontSize: 1.0 * rem)),
          ] else ...[
            Text('Discord should have opened. Tap Authorize there, then come back to PEK TV.', style: TextStyle(color: t.textMuted, fontSize: 1.0 * rem)),
            SizedBox(height: 0.75 * rem),
            Text('This screen closes by itself once Discord is linked.', style: TextStyle(color: t.textMuted, fontSize: 1.0 * rem)),
          ],
        ]);

        final Widget qr = s == null
            ? SizedBox(width: qrSize, height: qrSize, child: Center(child: _error.isEmpty ? const CircularProgressIndicator() : Icon(Icons.qr_code_2, size: 4 * rem, color: t.textMuted)))
            : QrImageView(data: s.url, size: qrSize, backgroundColor: Colors.white, padding: EdgeInsets.all(0.7 * rem));

        return ListView(padding: p.pagePad, children: [
          if (tv)
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [qr, SizedBox(width: 2.5 * rem), Expanded(child: steps)])
            else ...[Center(child: qr), SizedBox(height: 1.2 * rem), steps]
          else ...[
            steps,
            SizedBox(height: 1.0 * rem),
            Align(
              alignment: Alignment.centerLeft,
              child: PekButton(
                primary: true,
                label: 'Open Discord again',
                leading: Icon(Icons.open_in_new, size: 1.1 * rem, color: t.bg),
                onTap: s == null ? null : () => DiscordPresence.openUrl(s.url),
              ),
            ),
          ],
          SizedBox(height: 1.2 * rem),
          if (_error.isNotEmpty) ...[
            Padding(padding: EdgeInsets.only(bottom: 0.75 * rem), child: Text(_error, style: const TextStyle(color: Colors.redAccent))),
            Align(alignment: Alignment.centerLeft, child: PekButton(label: 'Try again', onTap: _start)),
          ],
          if (s != null) Padding(padding: EdgeInsets.only(bottom: 0.75 * rem), child: Text('This link works for ${_left(s)} more. A new one is made by itself.', style: TextStyle(color: t.textMuted, fontSize: 0.9 * rem))),
        ]);
      }),
    );
  }
}
