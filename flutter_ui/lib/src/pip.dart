import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Picture in picture (Android phones and tablets): pressing Home while a video plays, or the button in the player's top bar,
/// shrinks the app into a small floating window that keeps playing, like YouTube's. Live in Kotlin (FlutterHostActivity, the
/// `pek/pip` channel); this is the Dart side.
///
/// Only the player screen asks for it (live TV and music do not), and only one player screen at a time owns it: when one episode
/// replaces another the new screen claims it before the old one lets go.
class Pip {
  static const _ch = MethodChannel('pek/pip');

  /// True while Android shows the app as the small window. The player draws nothing but the picture then: no controls, no Skip
  /// button and no "Next episode" card (those need a finger and a full screen, and Up next does not work in the small window).
  static final active = ValueNotifier<bool>(false);

  static Object? _owner;
  static VoidCallback? _onToggle;
  static bool _hooked = false;

  static void _hook() {
    if (_hooked) return;
    _hooked = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'state': // entered or left the small window
          active.value = call.arguments == true;
          break;
        case 'toggle': // the play / pause button of the small window
          _onToggle?.call();
          break;
      }
      return null;
    });
  }

  /// Can this device do it (a phone or tablet with the system feature; never a TV box)?
  static Future<bool> supported() async {
    _hook();
    try {
      return (await _ch.invokeMethod<bool>('supported').timeout(const Duration(seconds: 2))) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// [owner] (a player screen) takes over and says what the small window should offer: [playing] decides whether Home shrinks
  /// the app (a paused video just goes to the background) and which way the window's play / pause button points.
  /// The aspect ratio of the window is read from the video when this is called, so call it again once the video is known.
  static void claim(Object owner, {required bool playing, required VoidCallback onToggle}) {
    _hook();
    _owner = owner;
    _onToggle = onToggle;
    _send(true, playing);
  }

  static void release(Object owner) {
    if (!identical(_owner, owner)) return; // a newer player screen has already taken over
    _owner = null;
    _onToggle = null;
    _send(false, false);
  }

  /// Shrinks the app now (the button in the top bar). False = the system would not (or the device cannot).
  static Future<bool> enter() async {
    try {
      return (await _ch.invokeMethod<bool>('enter')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static void _send(bool allowed, bool playing) {
    unawaited(_ch.invokeMethod<void>('set', {'allowed': allowed, 'playing': playing}).catchError((_) {}));
  }
}
