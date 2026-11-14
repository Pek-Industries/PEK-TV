import 'dart:io' show Platform;

/// What the platform underneath can do. The Flutter screens are shared by every host (android/, windows/, ...); anything that
/// only one host provides is asked here, so each host folder stays self-contained and the screens never test `Platform` inline.
class PekPlatform {
  PekPlatform._();

  static final bool isAndroid = Platform.isAndroid;
  static final bool isWindows = Platform.isWindows;
  static bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// The picture is drawn by the host on a surface BEHIND Flutter (Android's SurfaceView). On Windows it is a Flutter texture
  /// that Dart puts behind the screens itself ([PekVideoSurface], video_surface.dart).
  static bool get videoBehindFlutter => Platform.isAndroid;
  static bool get videoAsTexture => Platform.isWindows;

  /// Plugin trailers are YouTube pages in a web view. webview_flutter has no Windows implementation, so there are none there.
  static bool get hasWebView => Platform.isAndroid || Platform.isIOS;

  /// The phone's own speech recognizer (the Google keyboard's mic). Elsewhere the bundled Moonshine model listens.
  static bool get hasSystemRecognizer => Platform.isAndroid;
}
