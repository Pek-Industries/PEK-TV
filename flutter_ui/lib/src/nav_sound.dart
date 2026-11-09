import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'store.dart';

/// Navigation sounds, in the style of the Apple TV interface: a soft tick when the highlight moves, a two-note tone when you
/// select something (a tap on a phone, the centre button on a remote) and a lower tone when a screen or dialog closes.
///
/// - The sounds are made and played by the host (`NavSound.kt`, over `pek/host` > `navSound`) on a low-latency audio track, so
///   they land with the highlight instead of trailing it. A host without it (or a device where it could not be set up) is silent.
/// - **Move**: [install] listens to Flutter's focus. It only ticks while the focus ring is showing (remote / keyboard / game
///   controller), never for a touch, and not for focus that lands by itself when a screen opens or closes.
/// - **Select**: `PekFocusable` calls [select] for every tap and every centre-button press, so each button, row, poster and
///   tab makes the sound, and things that do nothing do not.
/// - **Back**: [observer] plays it when a route is popped (Back button, a closing dialog or sheet).
/// - Nothing plays while the video player is open ([mute] / [unmute]): a tick must not sit on top of a film's sound.
///
/// Settings > Sounds turns them off or sets Low / Medium / High. Like TV mode this belongs to the device, not to a profile.
class NavSounds {
  NavSounds._();

  static const _onKey = 'pek_nav_sound';
  static const _levelKey = 'pek_nav_sound_level';

  /// (id, label, volume 0..1)
  static const levels = <(int, String, double)>[(1, 'Low', 0.35), (2, 'Medium', 0.65), (3, 'High', 1.0)];
  static const defaultLevel = 2;

  static const _host = MethodChannel('pek/host');
  static const _move = 0, _select = 1, _back = 2; // the kinds NavSound.kt knows

  /// Bumped when a setting changes; Settings > Sounds rebuilds from it.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  // ---------------------------------------------------------------- settings (cached, so a press never waits for storage)

  static bool? _on;
  static int? _lvl;

  /// On unless the user turned it off.
  static bool get enabled {
    final c = _on;
    if (c != null) return c;
    try {
      return _on = Store.strGet(_onKey, scoped: false) != 'off';
    } catch (_) {
      return false; // storage is not ready (a test, or very early): stay quiet and ask again next time
    }
  }

  static int get level {
    final c = _lvl;
    if (c != null) return c;
    try {
      final v = int.tryParse(Store.strGet(_levelKey, scoped: false) ?? '');
      return _lvl = v != null && levels.any((l) => l.$1 == v) ? v : defaultLevel;
    } catch (_) {
      return defaultLevel;
    }
  }

  static double get _volume => levels.firstWhere((l) => l.$1 == level, orElse: () => levels[1]).$3;

  /// The change counts at once; saving to disk follows. Turning sounds on is heard right away, because the tap that did it
  /// plays its own select sound after this has run (see [select]).
  static Future<void> setEnabled(bool on) {
    _on = on;
    changes.value++;
    return Store.strSet(_onKey, on ? 'on' : 'off', scoped: false);
  }

  static Future<void> setLevel(int id) {
    final v = levels.any((l) => l.$1 == id) ? id : defaultLevel;
    _lvl = v;
    changes.value++;
    return Store.strSet(_levelKey, '$v', scoped: false);
  }

  // ---------------------------------------------------------------- muting (the video player)

  static int _mutes = 0;
  static void mute() => _mutes++;
  static void unmute() {
    if (_mutes > 0) _mutes--;
  }

  // ---------------------------------------------------------------- the three sounds

  static final Stopwatch _clock = Stopwatch()..start();
  static int get _now => _clock.elapsedMilliseconds;
  static int _lastMove = -10000, _lastSelect = -10000, _lastBack = -10000;

  /// The highlight moved to another item.
  static void move() {
    final t = _now;
    if (t - _lastMove < 55) return; // a held arrow key repeats fast: a ticking, not a buzz
    // A select or back has just happened and the screen that opened or closed put focus on something by itself: no tick for that.
    if (t - _lastSelect < 350 || t - _lastBack < 350) return;
    if (_play(_move)) _lastMove = t;
  }

  /// A tap or a centre-button press on something that does something.
  ///
  /// The time is noted now (so the Back sound of a dialog that closes because of this tap stays quiet), but the sound is
  /// started a moment later, after the tap's own handler has run: a button that turns the sounds on or off, or changes their
  /// volume, is then heard with its new setting.
  static void select() {
    final t = _now;
    if (t - _lastSelect < 90) return;
    _lastSelect = t;
    scheduleMicrotask(() => _play(_select));
  }

  /// A screen, dialog or sheet closed.
  static void back() {
    final t = _now;
    if (t - _lastSelect < 250) return; // it closed because of a selection that already had its sound
    if (t - _lastBack < 150) return;
    _lastBack = t;
    _play(_back);
  }

  static bool _play(int kind) {
    if (_mutes > 0 || !enabled) return false;
    // Fire and forget: the host plays on its own thread. Errors (no such channel in a test, an older host) just mean silence.
    unawaited(_host.invokeMethod<void>('navSound', <String, Object>{'kind': kind, 'volume': _volume}).catchError((_) {}));
    return true;
  }

  // ---------------------------------------------------------------- hooking into Flutter

  static bool _installed = false;
  static FocusNode? _lastFocus;

  /// Starts listening to focus changes. Call once, after `Store.init()`.
  static void install() {
    if (_installed) return;
    _installed = true;
    FocusManager.instance.addListener(_onFocus);
  }

  static void _onFocus() {
    final f = FocusManager.instance.primaryFocus;
    final before = _lastFocus;
    if (identical(f, before)) return;
    _lastFocus = f;
    if (f == null || before == null) return; // the first focus, or focus coming back after a screen closed
    if (before.parent == null) return; // the item that had focus is gone (its screen closed; a removed node has no parent): that is not the user moving
    if (f is FocusScopeNode) return;
    // Touch and mouse show no focus ring, so there is nothing to tick for. A remote, keyboard or game controller switches it on.
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) return;
    move();
  }

  /// Pass to `MaterialApp.navigatorObservers`: plays the Back sound when a route is popped.
  static final NavSoundObserver _obs = NavSoundObserver();
  static final List<NavigatorObserver> observers = <NavigatorObserver>[_obs];
}

class NavSoundObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => NavSounds.back();
}
