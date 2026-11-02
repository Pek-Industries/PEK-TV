import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';
import 'widgets.dart';

/// Android's "All files access" switch for PEK TV. Without it the app cannot open the folders of a USB drive or SD card.
class AllFilesAccess {
  static const _host = MethodChannel('pek/host');

  /// true when granted, or when this Android has no such switch (older than 11) or the question cannot be asked.
  static Future<bool> granted() async {
    try {
      return await _host.invokeMethod<bool>('allFilesAccess') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens Android's settings for it. The person turns the switch on and presses Back.
  static Future<bool> openSettings() async {
    try {
      return await _host.invokeMethod<bool>('openAllFilesAccess') ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// A notice with a button, shown only while "All files access" is off. Checks again when the app comes back from Android's settings.
class AllFilesAccessBanner extends StatefulWidget {
  const AllFilesAccessBanner({super.key, this.onGranted});
  final VoidCallback? onGranted; // e.g. the picker reloads its list

  @override
  State<AllFilesAccessBanner> createState() => _AllFilesAccessBannerState();
}

class _AllFilesAccessBannerState extends State<AllFilesAccessBanner> with WidgetsBindingObserver {
  bool _granted = true; // hidden until the answer is in

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final g = await AllFilesAccess.granted();
    if (!mounted) return;
    final changed = g && !_granted;
    setState(() => _granted = g);
    if (changed) widget.onGranted?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_granted) return const SizedBox.shrink();
    final p = context.pek;
    return Padding(
      padding: EdgeInsets.only(bottom: 0.75 * p.rem),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('To use folders on a USB drive or SD card, PEK TV needs \u201cAll files access\u201d. Turn it on for PEK TV, then come back.', style: TextStyle(color: p.tokens.textMuted)),
        SizedBox(height: 0.5 * p.rem),
        PekButton(
          compact: true,
          primary: true,
          label: 'Allow access to all files',
          onTap: () async {
            final ok = await AllFilesAccess.openSettings();
            if (!ok && mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Open Android Settings > Apps > PEK TV > Permissions and allow All files access.')));
            }
          },
        ),
      ]),
    );
  }
}
