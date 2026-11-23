import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'account_pages.dart' show AccountMode, AccountScreen;
import 'cloud.dart';
import 'deep_link.dart';
import 'l10n.dart';
import 'net.dart';
import 'server_connect.dart' show openServerConnect;
import 'server_target.dart';
import 'tokens.dart';
import 'widgets.dart';

/// What the account gate is showing.
enum GateState {
  /// Nothing: the account's server answers (or nobody is signed in).
  none,

  /// Signed in, but the account's server (PEK Cloud or the paired PEK Server) does not answer. The app is blocked, so nothing
  /// is changed on this device that could not be synced, and the person knows why. It tries again by itself.
  unreachable,

  /// The session was ended from elsewhere ([AccountGate.reason]: removed from the server, password changed, signed out by the
  /// server owner, or the PEK Cloud session ran out). This device is already signed out; the screen says so once.
  ended,

  /// The paired PEK Server got a new access key (pek-server --new-key): this device has to connect again.
  unpaired,
}

/// Watches the signed-in account's server and puts [AccountGateLayer] in front of the app when it cannot be used.
///
/// Unreachable is only decided after two failed tries a few seconds apart, so one dropped request never blocks anything. For a
/// PEK Cloud account it also needs the device itself to be online: with no internet at all the app keeps its usual offline mode
/// (the local library), sync simply waits. A self-hosted server is on the home network, so it is checked directly.
class AccountGate {
  static final ValueNotifier<GateState> state = ValueNotifier(GateState.none);

  /// [GateState.ended]: the code the server gave (account_removed, password_changed, signed_out_by_owner, session_expired).
  static String reason = '';

  /// Who the account was with, kept for the message (the session itself is gone by the time it shows).
  static String serverName = '';
  static bool selfHosted = false;

  /// When the next automatic try is due (shown as a countdown).
  static final ValueNotifier<DateTime?> nextTry = ValueNotifier(null);

  static bool get blocked => state.value == GateState.unreachable;

  static const _backoff = [15, 30, 60, 120]; // seconds between automatic tries
  static int _fails = 0;
  static Timer? _retry;
  static Future<bool>? _probing;
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    ServerTarget.needsPairing.addListener(_onPairing);
    ServerTarget.changes.addListener(_onTargetChanged);
    Net.status.addListener(_onNet);
    if (Cloud.linked) Timer(const Duration(seconds: 3), () => unawaited(probe()));
  }

  static void _remember() {
    selfHosted = Cloud.onServer || ServerTarget.remote;
    serverName = selfHosted ? ServerTarget.name : 'PEK Cloud';
  }

  static void _onPairing() {
    if (ServerTarget.needsPairing.value && ServerTarget.remote) {
      _remember();
      _set(GateState.unpaired);
    } else if (state.value == GateState.unpaired) {
      _set(GateState.none);
    }
  }

  static void _onTargetChanged() {
    // Another server, or back to this device: whatever was shown was about the old one.
    if (state.value == GateState.unreachable || state.value == GateState.unpaired) _set(GateState.none);
    if (Cloud.linked) unawaited(probe());
  }

  static void _onNet() {
    if (Net.isOnline && state.value == GateState.unreachable) unawaited(probe());
  }

  static void _set(GateState s) {
    if (s != GateState.unreachable) {
      _retry?.cancel();
      nextTry.value = null;
      _fails = 0;
    }
    state.value = s;
  }

  /// A signed-in call failed in a way that could mean the server is down: check (unless a check is already running).
  static void suspect() {
    if (state.value == GateState.none && Cloud.linked) unawaited(probe());
  }

  /// The session ended elsewhere (the device is already signed out): tell the person once.
  static void sessionEnded(String code) {
    _remember();
    reason = code;
    _set(GateState.ended);
  }

  /// Is the account's server there? Two tries 3 s apart. Blocks when it is not (see the class comment), unblocks and syncs
  /// when it is back. Returns true when it answered.
  static Future<bool> probe() => _probing ??= _probe().whenComplete(() => _probing = null);

  static Future<bool> _probe() async {
    if (!Cloud.linked) {
      if (state.value == GateState.unreachable) _set(GateState.none);
      return true;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      final r = await Cloud.ping();
      switch (r) {
        case 'ok':
          final wasBlocked = blocked;
          if (state.value == GateState.unreachable) _set(GateState.none);
          if (wasBlocked) unawaited(Cloud.sync()); // whatever waited goes now
          return true;
        case 'ended':
        case 'device_unpaired':
          return false; // Cloud.ping already showed the right screen
      }
      if (attempt == 0) await Future<void>.delayed(const Duration(seconds: 3));
    }
    // Still no answer. No internet at all on this device and a PEK Cloud account: that is the app's normal offline mode.
    if (!Cloud.onServer && !Net.isOnline) {
      if (state.value == GateState.unreachable) _set(GateState.none);
      return false;
    }
    _remember();
    _set(GateState.unreachable);
    final wait = _backoff[math.min(_fails, _backoff.length - 1)];
    _fails++;
    _retry?.cancel();
    nextTry.value = DateTime.now().add(Duration(seconds: wait));
    _retry = Timer(Duration(seconds: wait), () => unawaited(probe()));
    return false;
  }

  static void dismiss() {
    reason = '';
    _set(GateState.none);
  }

  /// Wraps the app (under [AccountGateLayer]): while the gate is up nothing behind it can take focus (TV remote, keyboard) or
  /// a tap. Always in the tree, so the app keeps its state.
  static Widget shield(Widget child) => ValueListenableBuilder<GateState>(
        valueListenable: state,
        builder: (context, s, c) => ExcludeFocus(excluding: s != GateState.none, child: IgnorePointer(ignoring: s != GateState.none, child: c!)),
        child: child,
      );
}

/// The screen in front of the whole app while [AccountGate.state] is not [GateState.none]. Sits in MaterialApp.builder, so it uses
/// [DeepLink.navKey] to open other screens.
class AccountGateLayer extends StatelessWidget {
  const AccountGateLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GateState>(
      valueListenable: AccountGate.state,
      builder: (context, s, _) => s == GateState.none ? const SizedBox.shrink() : _GateScreen(state: s),
    );
  }
}

class _GateScreen extends StatefulWidget {
  const _GateScreen({required this.state});
  final GateState state;
  @override
  State<_GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<_GateScreen> {
  bool _trying = false;
  bool _confirmSignOut = false; // asked here, not in a dialog: a dialog would open on the app's navigator, behind this screen
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.state == GateState.unreachable) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _tryAgain() async {
    setState(() => _trying = true);
    await AccountGate.probe();
    if (mounted) setState(() => _trying = false);
  }

  Future<void> _signOutNow() async {
    await Cloud.signOutOffline();
    AccountGate.dismiss();
  }

  void _signIn() {
    AccountGate.dismiss();
    DeepLink.navKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => const AccountScreen(mode: AccountMode.signIn)));
  }

  Future<void> _pairAgain() async {
    final nav = DeepLink.navKey.currentContext;
    if (nav == null) return;
    AccountGate.dismiss(); // the Connect screen must be usable; the gate comes back if the key is still wrong
    await openServerConnect(nav);
  }

  Future<void> _useDevice() async {
    AccountGate.dismiss();
    await ServerTarget.useThisDevice();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final name = AccountGate.serverName;
    late final IconData icon;
    late final String title;
    late final String body;
    final buttons = <Widget>[];

    switch (widget.state) {
      case GateState.unreachable when _confirmSignOut:
        icon = Icons.logout;
        title = 'Sign out on this device?'.tr;
        body = 'Anything watched since the last sync stays unsynced and leaves this device. Your account and everything already synced are kept on the server.'.tr;
        buttons.addAll([
          PekButton(label: 'Cancel'.tr, primary: true, autofocus: true, onTap: () => setState(() => _confirmSignOut = false)),
          PekButton(label: 'Sign out'.tr, onTap: _signOutNow),
        ]);
      case GateState.unreachable:
        icon = Icons.cloud_off_outlined;
        title = 'Can\u2019t access the server right now'.tr;
        body = AccountGate.selfHosted
            ? '{name} isn\u2019t answering. Check that it is switched on and that this device is on the same network, then try again. Your account is paused so nothing gets out of sync.'.trp({'name': name})
            : 'PEK Cloud isn\u2019t answering. Please try again later. Your account is paused so nothing gets out of sync.'.tr;
        buttons.addAll([
          PekButton(label: _trying ? 'Trying\u2026'.tr : 'Try again'.tr, primary: true, autofocus: true, onTap: _trying ? null : _tryAgain),
          PekButton(label: 'Sign out'.tr, onTap: _trying ? null : () => setState(() => _confirmSignOut = true)),
        ]);
      case GateState.ended:
        icon = Icons.logout;
        switch (AccountGate.reason) {
          case 'account_removed':
            title = 'You were removed from {name}'.trp({'name': name});
            body = 'The owner of the server removed your account, so you are signed out on this device. Ask them if you think this is a mistake.'.tr;
          case 'password_changed':
            title = 'Your password was changed'.tr;
            body = 'Your account on {name} has a new password, so this device was signed out. Sign in with the new password.'.trp({'name': name});
          case 'signed_out_by_owner':
            title = 'You were signed out'.tr;
            body = 'The owner of {name} signed your account out of its devices. You can sign in again.'.trp({'name': name});
          default:
            title = 'You were signed out'.tr;
            body = 'Your session ended (you may have signed out everywhere or changed your password). Sign in again to keep syncing.'.tr;
        }
        if (AccountGate.reason == 'account_removed') {
          buttons.add(PekButton(label: 'OK'.tr, primary: true, autofocus: true, onTap: AccountGate.dismiss));
        } else {
          buttons.addAll([
            PekButton(label: 'Sign in'.tr, primary: true, autofocus: true, onTap: _signIn),
            PekButton(label: 'Later'.tr, onTap: AccountGate.dismiss),
          ]);
        }
      case GateState.unpaired:
        icon = Icons.link_off;
        title = 'This device was disconnected from {name}'.trp({'name': name});
        body = 'The server has a new access key, so every TV and phone has to connect to it again.'.tr;
        buttons.addAll([
          PekButton(label: 'Pair again'.tr, primary: true, autofocus: true, onTap: _pairAgain),
          PekButton(label: 'Use this device instead'.tr, onTap: _useDevice),
        ]);
      case GateState.none:
        return const SizedBox.shrink();
    }

    String? countdown;
    final due = AccountGate.nextTry.value;
    if (widget.state == GateState.unreachable && due != null && !_trying && !_confirmSignOut) {
      final left = due.difference(DateTime.now()).inSeconds;
      countdown = left > 0 ? 'Trying again in {seconds} s'.trp({'seconds': '$left'}) : 'Trying again\u2026'.tr;
    }

    // Opaque and full screen; AccountGate.shield keeps focus and taps off the app behind it.
    return FocusScope(
      autofocus: true,
      child: Material(
        color: t.bg,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: p.safeX + 1.5 * rem, vertical: 2 * rem),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 34 * rem),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 4 * rem, color: t.accent),
                  SizedBox(height: 1.25 * rem),
                  Text(title, textAlign: TextAlign.center, style: TextStyle(color: t.text, fontSize: 1.6 * rem, fontWeight: FontWeight.w800, height: 1.2)),
                  SizedBox(height: 0.75 * rem),
                  Text(body, textAlign: TextAlign.center, style: TextStyle(color: t.textMuted, fontSize: rem, height: 1.45)),
                  if (countdown != null) ...[
                    SizedBox(height: 0.75 * rem),
                    Text(countdown, textAlign: TextAlign.center, style: TextStyle(color: t.textMuted, fontSize: 0.85 * rem)),
                  ],
                  SizedBox(height: 1.5 * rem),
                  Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 10, children: buttons),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
