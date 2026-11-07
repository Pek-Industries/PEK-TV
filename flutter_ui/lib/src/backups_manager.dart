import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'cloud.dart';
import 'common.dart';
import 'plugin_backup.dart';
import 'plugin_pins.dart';
import 'plugin_store.dart' show PluginInstaller;
import 'skins.dart';
import 'tokens.dart';
import 'widgets.dart';

/// Settings > Advanced > Downloads and backups: what is installed on this device and what is kept in the account, with a button to
/// delete each one, so the cloud storage (30 plugins / 60 MB) and the device do not fill up with things nobody uses.
///
///  - Plugins: the ones installed here, and the ones backed up in the cloud (including copies of plugins that are not on this
///    device). "Remove from device" uninstalls; "Delete backup" frees the cloud copy and keeps the plugin on this device.
///  - Skins: the ones this profile made or installed. Skins are backed up with the profile, so deleting one removes it here and
///    from the account (the delete follows on the next sync).
class BackupsSection extends StatefulWidget {
  const BackupsSection({super.key});
  @override
  State<BackupsSection> createState() => _BackupsSectionState();
}

class _Plugin {
  _Plugin(this.id);
  final String id;
  String name = '';
  String version = '';
  bool onDevice = false;
  bool inCloud = false;
  bool builtin = false;
  int size = 0, updated = 0;
}

class _Data {
  const _Data(this.plugins, this.cloudOk);
  final List<_Plugin> plugins;
  final bool cloudOk; // false: signed out, or the cloud could not be read just now
}

class _BackupsSectionState extends State<BackupsSection> {
  late Future<_Data> _data = _load();
  bool _busy = false;

  Future<_Data> _load() async {
    List<PluginInfo> local;
    try {
      local = await Api.plugins();
    } catch (_) {
      local = const [];
    }
    final cloud = await PluginBackup.cloudCopies();
    final byId = <String, _Plugin>{};
    for (final p in local) {
      if (p.builtin || PluginInstaller.stockIds.contains(p.folder) || PluginBackup.builtin.contains(p.folder)) continue;
      final r = byId.putIfAbsent(p.folder, () => _Plugin(p.folder));
      r.name = p.name.isEmpty ? p.folder : p.name;
      r.version = p.version;
      r.onDevice = true;
    }
    for (final c in cloud ?? const <BackupOffer>[]) {
      final r = byId.putIfAbsent(c.id, () => _Plugin(c.id));
      if (r.name.isEmpty) r.name = c.name;
      if (r.version.isEmpty) r.version = c.version;
      r.inCloud = true;
      r.size = c.size;
      r.updated = c.updated;
    }
    final list = byId.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return _Data(list, cloud != null);
  }

  void _reload() {
    if (mounted) setState(() => _data = _load());
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<bool> _ask(String title, String body, String yes) async {
    final p = context.pek;
    final r = await showDialog<bool>(
      context: context,
      barrierColor: p.tokens.overlay,
      builder: (c) => AlertDialog(
        backgroundColor: p.tokens.glassStrong,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _deleteBackup(_Plugin r) async {
    final here = r.onDevice ? ' It stays installed on this device and will not be backed up again until you choose "Back up again".' : '';
    if (!await _ask('Delete the backup of \u201c${r.name}\u201d?', 'The copy in your account is deleted, which frees its space.$here', 'Delete backup')) return;
    setState(() => _busy = true);
    final err = await PluginBackup.deleteBackup(r.id);
    if (!mounted) return;
    setState(() => _busy = false);
    _say(err.isEmpty ? 'Deleted the backup of ${r.name}' : PluginBackup.errorText(err));
    _reload();
  }

  Future<void> _removeFromDevice(_Plugin r) async {
    final cloud = r.inCloud ? ' Its backup in your account is deleted too.' : '';
    if (!await _ask('Remove \u201c${r.name}\u201d from this device?', 'Its files are deleted from this device.$cloud You can install it again later.', 'Remove')) return;
    setState(() => _busy = true);
    final ok = await Api.uninstallPlugin(r.id).catchError((_) => false);
    if (ok) {
      await PluginInstaller.forgetSource(r.id);
      unawaited(PluginPins.forget(r.id));
      await PluginBackup.forget(r.id); // marks it removed in the cloud so no device offers it again
      await PluginInstaller.changed(r.id); // closes its open screen and reloads the menu
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _say(ok ? 'Removed ${r.name}' : 'Could not remove ${r.name}');
    _reload();
  }

  Future<void> _backUpAgain(_Plugin r) async {
    await PluginBackup.backUpAgain(r.id);
    if (!mounted) return;
    _say('${r.name} will be backed up again');
    Future<void>.delayed(const Duration(seconds: 3), _reload);
  }

  Future<void> _deleteSkin(Skin s) async {
    final cloud = Cloud.linked ? ' It is removed from your account too, and from your other devices on their next sync.' : '';
    if (!await _ask('Delete the skin \u201c${s.name}\u201d?', 'It is deleted from this profile.$cloud', 'Delete')) return;
    await Skins.deleteCustom(s.id);
    if (Cloud.linked) unawaited(Cloud.sync(light: true)); // the delete reaches the account
    if (!mounted) return;
    _say('Deleted ${s.name}');
    setState(() {});
  }

  String _size(int b) => b >= 1024 * 1024 ? '${(b / 1024 / 1024).toStringAsFixed(1)} MB' : '${(b / 1024).ceil()} KB';

  String _date(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Widget _pluginRow(_Plugin r, double rem) {
    final off = r.onDevice && !r.inCloud && PluginBackup.excluded(r.id);
    final where = r.onDevice && r.inCloud
        ? 'On this device and backed up'
        : r.onDevice
            ? (off ? 'On this device \u00b7 backup deleted' : 'On this device only')
            : 'Backed up only (not on this device)';
    final subtitle = [
      where,
      if (r.inCloud && r.size > 0) _size(r.size),
      if (r.inCloud && r.updated > 0) 'saved ${_date(r.updated)}',
    ].join(' \u00b7 ');
    return ListRow(
      title: r.version.isEmpty ? r.name : '${r.name}  v${r.version}',
      subtitle: subtitle,
      trailingBelow: context.pek.compact,
      trailing: Wrap(spacing: 0.5 * rem, runSpacing: 0.5 * rem, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (r.inCloud) PekButton(compact: true, label: 'Delete backup', onTap: _busy ? null : () => _deleteBackup(r)),
        if (off) PekButton(compact: true, label: 'Back up again', onTap: _busy ? null : () => _backUpAgain(r)),
        if (r.onDevice) PekButton(compact: true, label: 'Remove from device', onTap: _busy ? null : () => _removeFromDevice(r)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    final muted = TextStyle(color: p.tokens.textMuted, fontSize: 0.9 * rem);
    final skins = Skins.customSkins;
    return Section(
      title: 'Downloads and backups',
      hint: 'See what is installed on this device and what is saved in your account, and delete what you do not need.',
      children: [
        Text('Plugins', style: TextStyle(fontSize: rem, fontWeight: FontWeight.w600)),
        SizedBox(height: 0.4 * rem),
        FutureBuilder<_Data>(
          future: _data,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return Padding(padding: EdgeInsets.symmetric(vertical: rem), child: const Center(child: CircularProgressIndicator()));
            }
            final d = snap.data ?? const _Data([], false);
            final note = !Cloud.linked
                ? 'Sign in to see the plugins backed up in your account.'
                : !d.cloudOk
                    ? 'Could not reach your account just now, so only what is on this device is listed.'
                    : '';
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (note.isNotEmpty) Padding(padding: EdgeInsets.only(bottom: 0.5 * rem), child: Text(note, style: muted)),
              if (d.plugins.isEmpty)
                Padding(padding: EdgeInsets.only(bottom: 0.5 * rem), child: Text('No plugins installed or backed up.', style: muted))
              else
                for (final r in d.plugins) _pluginRow(r, rem),
              Padding(
                padding: EdgeInsets.only(top: 0.5 * rem),
                child: Wrap(spacing: 0.6 * rem, runSpacing: 0.6 * rem, children: [
                  PekButton(compact: true, label: 'Refresh', onTap: _busy ? null : _reload),
                ]),
              ),
            ]);
          },
        ),
        SizedBox(height: 1.2 * rem),
        Text('Skins', style: TextStyle(fontSize: rem, fontWeight: FontWeight.w600)),
        SizedBox(height: 0.2 * rem),
        Text(Cloud.linked ? 'Skins are saved in your account with this profile.' : 'Sign in to save your skins in your account.', style: muted),
        SizedBox(height: 0.4 * rem),
        if (skins.isEmpty)
          Text('No skins made or installed on this profile.', style: muted)
        else
          for (final s in skins)
            ListRow(
              title: s.version.isEmpty ? s.name : '${s.name}  v${s.version}',
              subtitle: [
                s.id.startsWith(Skins.installedPrefix) ? 'Installed' : 'Made in the skin maker',
                if (s.author.isNotEmpty) 'by ${s.author}',
                if (Cloud.linked) 'saved in your account',
                if (s.updated > 1) _date(s.updated),
              ].join(' \u00b7 '),
              trailing: PekButton(compact: true, label: 'Delete', onTap: _busy ? null : () => _deleteSkin(s)),
            ),
      ],
    );
  }
}
