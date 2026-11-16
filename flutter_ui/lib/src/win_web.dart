import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'api.dart' show Api;
import 'trailer_page.dart';

/// Windows only: the web view (Microsoft Edge WebView2, through `webview_flutter_windows`). It draws into a Flutter texture, so the
/// screens can be painted on top of it like on Android. Used for plugin trailers ([WinTrailerController]) and the start-up video
/// (win_splash.dart). A PC without the WebView2 runtime (Windows 11 and current Windows 10 have it) simply gets neither: [create]
/// returns null and the callers carry on without a trailer / splash.
class WinWeb {
  WinWeb._();

  static int _live = 0;

  /// A new, initialized controller, or null when WebView2 is not there or could not start.
  static Future<WebviewController?> create() async {
    if (!Platform.isWindows) return null;
    try {
      if (_live == 0) {
        // The environment is shared and goes away with the last controller, so its settings are given again each time the first one
        // starts. Autoplay: a trailer and the start-up video begin by themselves, with their sound.
        final local = Platform.environment['LOCALAPPDATA'];
        try {
          await WebviewController.initializeEnvironment(
            userDataPath: local == null || local.isEmpty ? null : '$local\\PEK TV\\webview',
            additionalArguments: '--autoplay-policy=no-user-gesture-required',
          );
        } catch (_) {/* already set up by a controller still alive */}
      }
      final c = WebviewController();
      _live++;
      try {
        await c.initialize();
        await c.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
        return c;
      } catch (_) {
        release(c);
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Gives a controller from [create] back.
  static void release(WebviewController c) {
    if (_live > 0) _live--;
    try {
      unawaited(c.dispose().catchError((Object _) {}));
    } catch (_) {}
  }
}

/// Windows only: one trailer. Plays the plain stream from this app's own server (`/api/trailer`) in a WebView2 page; there is no
/// YouTube fallback here (that needs the page to say it is embedded from YouTube's own address, which WebView2's string pages
/// cannot), so a title the server cannot give a stream for shows no trailer, and the picture under it stays.
class WinTrailerController {
  WinTrailerController();

  /// Bumped whenever [web], [failed] or [started] change; the widget rebuilds from it.
  final ValueNotifier<int> changes = ValueNotifier(0);

  WebviewController? web;
  StreamSubscription<dynamic>? _sub;
  bool started = false;
  bool ready = false;
  bool failed = false;
  bool _disposed = false;
  bool _active = true;

  void _bump() {
    if (!_disposed) changes.value++;
  }

  Future<void> start({required String id, required bool play, required bool muted, required bool seeThrough}) async {
    if (started) return;
    started = true;
    _active = play;
    _bump();
    final info = await Api.trailerStream(id);
    if (_disposed) return;
    if (info == null) return _fail();
    final c = await WinWeb.create();
    if (c == null) return _fail();
    if (_disposed) {
      WinWeb.release(c);
      return;
    }
    web = c;
    try {
      await c.setBackgroundColor(seeThrough ? Colors.transparent : Colors.black);
      _sub = c.webMessage.listen((m) {
        if (m == 'error') _fail(); // the video cannot play: no trailer
      });
      final video = Api.withToken(Api.abs('${info['video']}'));
      final audioPath = '${info['audio'] ?? ''}';
      final audio = audioPath.isEmpty ? '' : Api.withToken(Api.abs(audioPath));
      await c.loadStringContent(trailerPageHtml(video: video, audio: audio, play: _active, muted: muted, seeThrough: seeThrough));
      if (_disposed) return;
      ready = true;
      _bump();
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (_disposed || failed) return;
    failed = true;
    _release();
    _bump();
  }

  /// Same commands as Android's page understands: 'playVideo' / 'pauseVideo'.
  void command(String fn) {
    _active = fn == 'playVideo';
    final c = web;
    if (c == null || !ready || _disposed) return;
    try {
      unawaited(c.executeScript("post({event:'command',func:'$fn',args:[]})").then<void>((_) {}).catchError((Object _) {}));
    } catch (_) {}
  }

  void _release() {
    unawaited(_sub?.cancel());
    _sub = null;
    final c = web;
    web = null;
    ready = false;
    if (c != null) WinWeb.release(c);
  }

  /// The page that owned the trailer is gone: let go of the web view.
  void dispose() {
    if (_disposed) return;
    _release();
    _disposed = true;
  }
}

/// Windows only: the trailer's picture. Takes no clicks and no focus, so the page it sits in keeps working with the mouse and keys.
class WinTrailerView extends StatelessWidget {
  const WinTrailerView({super.key, required this.controller, required this.seeThrough});
  final WinTrailerController controller;
  final bool seeThrough;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: ColoredBox(
        color: seeThrough ? Colors.transparent : Colors.black,
        child: ValueListenableBuilder<int>(
          valueListenable: controller.changes,
          builder: (_, __, ___) {
            final c = controller.web;
            if (controller.failed || c == null || !controller.ready) return const SizedBox.expand();
            return IgnorePointer(child: ExcludeFocus(child: Webview(c)));
          },
        ),
      ),
    );
  }
}
