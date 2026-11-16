import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'platform.dart';
import 'win_web.dart';

/// Windows only: the PEK start-up video (the Android SplashActivity's counterpart). It covers the app while the server and the first
/// screen load, plays once per run and lifts when the video has ended AND the app has said it is ready (`WinSplash.appReady`, called
/// where Android sends `splashReady`). It plays in a WebView2 page and can never trap the person: no WebView2 runtime, a missing file,
/// no picture after a few seconds or a video that never ends all lift it. The orange under it is the colour of the loading screen.
///
/// The video files (`pek_splash.mp4`, `pek_splash_portrait.mp4`) are the Android ones; `windows/scripts/prepare-flutter-host.sh` copies
/// them into the Windows build's assets (they are not in `flutter_ui/`, so the Android app does not carry them twice).
class WinSplash extends StatefulWidget {
  const WinSplash({super.key});

  static final ValueNotifier<bool> _ready = ValueNotifier(false);
  static bool _finished = false; // one splash per run

  /// The app has loaded (server up, first real screen built): the video may lift once it has finished.
  static void appReady() => _ready.value = true;

  @override
  State<WinSplash> createState() => _WinSplashState();
}

class _WinSplashState extends State<WinSplash> {
  static const _orange = Color(0xFFE04A00); // pek_splash_bg
  static const _firstFrameTimeout = Duration(seconds: 5);
  static const _hardLimit = Duration(seconds: 20);
  static const _afterEndWait = Duration(seconds: 6); // the video is over but the app is not ready: lift anyway

  WebviewController? _web;
  StreamSubscription<dynamic>? _sub;
  Timer? _firstFrame, _hard, _afterEnd;
  bool _gone = false;
  bool _fading = false;
  bool _videoDone = false;

  @override
  void initState() {
    super.initState();
    if (!PekPlatform.isWindows || WinSplash._finished) {
      _gone = true;
      return;
    }
    WinSplash._finished = true;
    WinSplash._ready.addListener(_check);
    _hard = Timer(_hardLimit, _lift);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final portrait = view.physicalSize.height > view.physicalSize.width;
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final video = File('$exeDir\\data\\flutter_assets\\assets\\splash\\${portrait ? 'pek_splash_portrait' : 'pek_splash'}.mp4');
      if (!video.existsSync()) return _videoOver();

      // WebView2 only lets a page from a file address play a file, so the page is written next to the other caches.
      final local = Platform.environment['LOCALAPPDATA'];
      final dir = Directory(local == null || local.isEmpty ? Directory.systemTemp.path : '$local\\PEK TV\\cache');
      dir.createSync(recursive: true);
      final page = File('${dir.path}\\splash.html');
      page.writeAsStringSync(_html(Uri.file(video.path).toString()));

      final c = await WinWeb.create();
      if (c == null) return _videoOver();
      if (!mounted || _gone) {
        WinWeb.release(c);
        return;
      }
      _web = c;
      _sub = c.webMessage.listen((m) {
        if (m == 'playing') {
          _firstFrame?.cancel();
          if (mounted) setState(() {}); // the picture is there: show it
        } else if (m == 'ended' || m == 'error') {
          _videoOver();
        }
      });
      _firstFrame = Timer(_firstFrameTimeout, _videoOver); // no picture after a few seconds: skip the video
      await c.setBackgroundColor(_orange);
      await c.loadUrl(Uri.file(page.path).toString());
      if (mounted) setState(() {});
    } catch (_) {
      _videoOver();
    }
  }

  static String _html(String video) => '<!DOCTYPE html><html><head><meta charset="utf-8"><style>'
      'html,body{margin:0;height:100%;background:#E04A00;overflow:hidden}'
      'video{position:absolute;left:0;top:0;width:100%;height:100%;object-fit:contain;pointer-events:none}'
      '</style></head><body><video id="v" src="$video" autoplay playsinline preload="auto" disablepictureinpicture></video><script>'
      "var v=document.getElementById('v');"
      "function t(m){try{window.chrome.webview.postMessage(m)}catch(e){}}"
      "v.addEventListener('playing',function(){t('playing')});"
      "v.addEventListener('ended',function(){t('ended')});"
      "v.addEventListener('error',function(){t('error')});"
      "var p=v.play();if(p&&p.catch)p.catch(function(){t('error')});"
      '</script></body></html>';

  void _videoOver() {
    if (_videoDone) return;
    _videoDone = true;
    _firstFrame?.cancel();
    _afterEnd = Timer(_afterEndWait, _lift);
    _check();
  }

  void _check() {
    if (_videoDone && WinSplash._ready.value) _lift();
  }

  void _lift() {
    if (_fading || _gone || !mounted) return;
    _fading = true;
    setState(() {});
  }

  void _finish() {
    if (_gone) return;
    _gone = true;
    _cleanup();
    if (mounted) setState(() {});
  }

  void _cleanup() {
    WinSplash._ready.removeListener(_check);
    _firstFrame?.cancel();
    _hard?.cancel();
    _afterEnd?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
    final c = _web;
    _web = null;
    if (c != null) WinWeb.release(c);
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    final c = _web;
    return Positioned.fill(
      child: AbsorbPointer(
        child: AnimatedOpacity(
          opacity: _fading ? 0 : 1,
          duration: const Duration(milliseconds: 300),
          onEnd: () {
            if (_fading) _finish();
          },
          child: ColoredBox(
            color: _orange,
            child: (c != null && c.value.isInitialized) ? Webview(c) : const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}
