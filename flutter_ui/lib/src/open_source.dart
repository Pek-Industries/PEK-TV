import 'package:flutter/material.dart';

import 'common.dart';
import 'plugin_host.dart' show PluginHost;
import 'tokens.dart';

/// One open source library PEK TV is built with.
class OssLib {
  const OssLib(this.name, this.use, this.license, this.url);
  final String name;
  final String use; // what PEK TV uses it for
  final String license; // short license name
  final String url; // the licence text (https)
}

/// Settings > Open source. Keep this list in step with flutter_ui/pubspec.yaml, android/app/build.gradle,
/// android/app/src/main/cpp/CMakeLists.txt and the clone steps in .github/workflows/build_android.yml.
const List<(String, List<OssLib>)> ossGroups = [
  ('PEK TV', [
    OssLib('PEK TV', 'This app, free software under the GNU Affero General Public License v3 (AGPL-3.0). Tap for the licence', 'AGPL-3.0', 'https://github.com/Pek-Industries/PEK-TV/blob/HEAD/LICENCE'),
    OssLib('PEK TV source code', 'The full source of the app and the cloud workers, so you can self-host. Tap to open it', 'AGPL-3.0', 'https://github.com/Pek-Industries/PEK-TV'),
  ]),
  ('App interface (Flutter)', [
    OssLib('Flutter', 'The framework the app screens are built with', 'BSD 3-Clause', 'https://github.com/flutter/flutter/blob/master/LICENSE'),
    OssLib('http', 'Talking to the PEK TV server and online services', 'BSD 3-Clause', 'https://pub.dev/packages/http/license'),
    OssLib('shared_preferences', 'Remembering your settings', 'BSD 3-Clause', 'https://pub.dev/packages/shared_preferences/license'),
    OssLib('crypto', 'Hashing and signatures', 'BSD 3-Clause', 'https://pub.dev/packages/crypto/license'),
    OssLib('share_plus', 'Sharing the history and ratings export', 'BSD 3-Clause', 'https://pub.dev/packages/share_plus/license'),
    OssLib('webview_flutter', 'Plugin trailers', 'BSD 3-Clause', 'https://pub.dev/packages/webview_flutter/license'),
    OssLib('webview_flutter_android', 'Plugin trailers (Android)', 'BSD 3-Clause', 'https://pub.dev/packages/webview_flutter_android/license'),
    OssLib('image_picker', 'Choosing a playlist picture', 'BSD 3-Clause', 'https://pub.dev/packages/image_picker/license'),
    OssLib('path_provider', 'Where pictures and files are kept', 'BSD 3-Clause', 'https://pub.dev/packages/path_provider/license'),
    OssLib('qr_flutter', 'The QR code on the phone sign-in screen', 'BSD 3-Clause', 'https://pub.dev/packages/qr_flutter/license'),
    OssLib('Material Icons and Roboto', 'Icons and text font', 'Apache 2.0', 'https://www.apache.org/licenses/LICENSE-2.0'),
  ]),
  ('Playback and server', [
    OssLib('mpv (libmpv)', 'The video and audio player', 'GPL 2+ / LGPL 2.1+ (depends on the build)', 'https://github.com/mpv-player/mpv/blob/master/Copyright'),
    OssLib('libmpv for Android (jarnedemeulemeester)', 'Packages mpv for Android', 'MIT', 'https://github.com/jarnedemeulemeester/libmpv-android/blob/main/LICENSE'),
    OssLib('FFmpeg', 'Decoding inside mpv', 'LGPL 2.1+ / GPL 2+ (depends on the build)', 'https://ffmpeg.org/legal.html'),
    OssLib('cpp-httplib', 'The built-in web server', 'MIT', 'https://github.com/yhirose/cpp-httplib/blob/master/LICENSE'),
    OssLib('OpenSSL', 'Secure connections (HTTPS)', 'Apache 2.0', 'https://github.com/openssl/openssl/blob/master/LICENSE.txt'),
    OssLib('SQLite', 'The library and music databases', 'Public domain', 'https://www.sqlite.org/copyright.html'),
    OssLib('libsmb2', 'SMB network folders', 'LGPL 2.1', 'https://github.com/sahlberg/libsmb2/blob/master/LICENCE-LGPL-2.1.txt'),
    OssLib('libnfs', 'NFS network folders', 'LGPL 2.1', 'https://github.com/sahlberg/libnfs/blob/master/COPYING'),
    OssLib('libtorrent (rasterbar)', 'Torrent streaming', 'BSD 3-Clause', 'https://github.com/arvidn/libtorrent/blob/RC_2_0/LICENSE'),
    OssLib('Boost', 'Used by libtorrent', 'Boost Software License 1.0', 'https://www.boost.org/LICENSE_1_0.txt'),
    OssLib('Discord Social SDK', 'Discord Rich Presence', 'Proprietary (Discord terms, not open source)', 'https://discord.com/developers/docs/policies-and-agreements/developer-terms-of-service'),
  ]),
  ('Plugins and Android', [
    OssLib('Chaquopy', 'Runs plugins written in Python on Android', 'MIT', 'https://github.com/chaquo/chaquopy/blob/master/LICENSE.txt'),
    OssLib('Python', 'The language plugins are written in', 'PSF License', 'https://docs.python.org/3/license.html'),
    OssLib('AndroidX and Kotlin', 'Android building blocks', 'Apache 2.0', 'https://www.apache.org/licenses/LICENSE-2.0'),
  ]),
];

/// Opens a licence link. When the device has no browser (some TVs), shows the address instead so it can be read.
Future<void> _openLicense(BuildContext context, OssLib lib) async {
  final ok = await PluginHost.openUrl(lib.url);
  if (ok || !context.mounted) return;
  final p = context.pek;
  await showDialog<void>(
    context: context,
    barrierColor: p.tokens.overlay,
    builder: (c) => AlertDialog(
      backgroundColor: p.tokens.glassStrong,
      title: Text('${lib.name} licence'),
      content: SelectableText('No browser is available on this device. The licence is at:\n\n${lib.url}'),
      actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(c), child: const Text('Close'))],
    ),
  );
}

/// The body of Settings > Open source.
class OpenSourceSection extends StatelessWidget {
  const OpenSourceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.only(bottom: 0.5 * rem),
        child: Text(
          'PEK TV is built with the open source libraries below. Tap one to read its licence.',
          style: TextStyle(color: t.textMuted, fontSize: 0.9 * rem),
        ),
      ),
      for (final g in ossGroups)
        SettingsGroup(title: g.$1, children: [
          for (final lib in g.$2)
            ListRow(
              title: lib.name,
              subtitle: '${lib.license}  \u00b7  ${lib.use}',
              trailing: Icon(Icons.open_in_new, color: t.textMuted),
              onTap: () => _openLicense(context, lib),
            ),
        ]),
    ]);
  }
}
