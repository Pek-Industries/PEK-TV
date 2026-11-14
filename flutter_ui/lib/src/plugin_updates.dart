import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';
import 'plugin_github.dart';
import 'plugin_install_ui.dart';
import 'plugin_store.dart';
import 'plugin_store_ui.dart';
import 'store.dart';
import 'tokens.dart';
import 'widgets.dart';

/// Keeps installed plugins up to date. Checked once when the app starts (a few seconds in, so the start is not slowed down) and
/// again when the Plugins page asks.
///
///  * Built-in plugins (Weather, TMDb Discover, Skin maker) come from the PEK Store's Official shelf. A newer version there is installed by
///    itself: it is PEK's own plugin, published by the owner.
///  * A plugin installed from GitHub is looked up on GitHub again (its latest release). A newer one is only OFFERED on the Plugins
///    page: it is third-party code from an unverified developer, so the person sees the permissions screen again and taps Update.
///  * Plugins installed from the PEK Store (Official or Community shelf) are looked up on the store again. A newer version is OFFERED
///    on the Updates screen (the dot on its tab), never installed by itself: the person taps it and lands on the install screen.
///  * Plugins from a .zip file are not checked here.
///  * The check runs a few seconds after start, again every few hours while the app stays open, and whenever Updates opens.
class PluginUpdates {
  /// GitHub plugins with a newer release, by plugin id.
  static final ValueNotifier<Map<String, GithubUpdate>> github = ValueNotifier(const {});

  /// Store plugins (Official or Community shelf) with a newer version, by plugin id.
  static final ValueNotifier<Map<String, StoreUpdate>> store = ValueNotifier(const {});

  /// How many available updates (GitHub + store) the person has not seen on the Updates screen yet: the dot on its tab.
  static final ValueNotifier<int> unseen = ValueNotifier(0);

  static const _kSeen = 'pek_plugin_updates_seen';

  /// Built-in plugins that were updated from the store during this run (for a one-time message on the Plugins page).
  static final ValueNotifier<List<String>> updatedStock = ValueNotifier(const []);

  static bool _started = false;
  static bool _checking = false;

  static void checkOnStartup() {
    if (_started) return;
    _started = true;
    Timer(const Duration(seconds: 6), () => unawaited(check()));
    Timer.periodic(const Duration(hours: 3), (_) => unawaited(check())); // while the app stays open
  }

  /// One key per offered update ("store:id@version", "gh:id@tag"): a newer release later is a new key, so the dot comes back.
  static List<String> currentKeys() => [
        for (final e in github.value.entries) 'gh:${e.key}@${e.value.release.tag}',
        for (final e in store.value.entries) 'store:${e.key}@${e.value.item.version}',
      ];

  /// The keys the person has already seen on the Updates screen.
  static Set<String> seenKeys() {
    try {
      final raw = Store.strGet(_kSeen, scoped: false);
      if (raw == null || raw.isEmpty) return {};
      return {for (final e in (jsonDecode(raw) as List)) '$e'};
    } catch (_) {
      return {};
    }
  }

  static void _recount() {
    final seen = seenKeys();
    unseen.value = currentKeys().where((k) => !seen.contains(k)).length;
  }

  /// The Updates screen was opened: everything offered so far counts as seen (the dot goes away).
  static Future<void> markSeen() async {
    final keys = currentKeys();
    if (keys.isEmpty) {
      unseen.value = 0;
      return;
    }
    final seen = seenKeys()..addAll(keys);
    final list = seen.toList();
    await Store.strSet(_kSeen, jsonEncode(list.length > 60 ? list.sublist(list.length - 60) : list), scoped: false);
    unseen.value = 0;
  }

  /// 1.10.0 is newer than 1.9.2; a missing number counts as 0. Letters after a number are ignored (1.2.0-rc = 1.2.0).
  static bool newer(String a, String b) {
    List<int> parts(String v) => v.trim().replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[.\-+]')).map((e) => int.tryParse(RegExp(r'^\d+').stringMatch(e) ?? '') ?? 0).toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d > 0;
    }
    return false;
  }

  static Future<void> check() async {
    if (_checking) return;
    _checking = true;
    try {
      final List<PluginInfo> installed;
      try {
        installed = await Api.plugins();
      } catch (_) {
        return; // the server is not answering: try again next time
      }
      await _stock(installed);
      await _github(installed);
      await _store(installed);
      _recount();
    } finally {
      _checking = false;
    }
  }

  static Future<void> _stock(List<PluginInfo> installed) async {
    final mine = {for (final p in installed) if (PluginInstaller.stockIds.contains(p.folder)) p.folder: p.version};
    if (mine.isEmpty) return;
    List<StoreItem> items;
    try {
      items = await PekStoreApi.list('official');
    } catch (_) {
      return; // offline: nothing to do
    }
    for (final it in items) {
      final have = mine[it.id];
      if (have == null || it.version.isEmpty) continue;
      if (!newer(it.version, have)) continue;
      try {
        final prep = await PekStoreApi.download(it, official: true);
        final verdict = await PluginInstaller.send(prep, dry: true);
        if (!verdict.ok) continue;
        final res = await PluginInstaller.send(prep, dry: false);
        if (!res.ok) continue;
        await PluginInstaller.rememberSource(prep.id, 'official');
        await PluginInstaller.changed(prep.id);
        updatedStock.value = [...updatedStock.value, '${prep.name} ${prep.version}'];
      } catch (_) {
        // Try again at the next start.
      }
    }
  }

  static Future<void> _github(List<PluginInfo> installed) async {
    if (!PekGithub.enabled) return;
    final found = <String, GithubUpdate>{};
    for (final p in installed) {
      final src = PluginInstaller.sourceOf(p.folder);
      if (src is! Map || src['type'] != 'github') continue;
      final owner = '${src['owner']}', repo = '${src['repo']}', tag = '${src['tag'] ?? ''}';
      if (owner.isEmpty || repo.isEmpty) continue;
      try {
        final rel = await PekGithub.findRelease(owner, repo, pek: true);
        if (rel.options.isEmpty) continue; // no .PEK file in the release: nothing PEK TV could install
        if (rel.tag.isEmpty || rel.tag == tag) continue; // no release, or the one that is installed
        if (tag.isNotEmpty && !newer(rel.tag, tag) && RegExp(r'\d').hasMatch(rel.tag) && RegExp(r'\d').hasMatch(tag)) continue; // an older / same number
        found[p.folder] = GithubUpdate(plugin: p, release: rel, kind: '${src['kind'] ?? 'source'}');
      } catch (_) {}
    }
    github.value = found;
  }

  /// Plugins installed from the PEK Store (Official or Community shelf, not the built-in ones: those update by themselves above).
  static Future<void> _store(List<PluginInfo> installed) async {
    final mine = <String, PluginInfo>{};
    for (final p in installed) {
      final src = PluginInstaller.sourceOf(p.folder);
      if (src == 'community' || (src == 'official' && !PluginInstaller.stockIds.contains(p.folder))) mine[p.folder] = p;
    }
    if (mine.isEmpty) {
      store.value = const {};
      return;
    }
    List<StoreItem> items;
    try {
      items = await PekStoreApi.listAll();
    } catch (_) {
      return; // offline: keep what we knew
    }
    final found = <String, StoreUpdate>{};
    for (final it in items) {
      final have = mine[it.id];
      if (have == null || it.version.isEmpty || have.version.isEmpty) continue;
      if (!newer(it.version, have.version)) continue;
      found[it.id] = StoreUpdate(plugin: have, item: it);
    }
    store.value = found;
  }

  /// Opens the install screen for a store update: the same permissions screen as a first install, straight in the app.
  static Future<void> openStoreUpdate(BuildContext context, StoreUpdate u) async {
    final it = u.item;
    final shelf = it.shelf == 'official' ? 'official' : 'community';
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SubScreen(
          title: 'Update ${it.name}',
          body: Builder(
            builder: (c) => PluginInstallPage(
              title: it.name,
              shelf: shelf,
              load: (progress) => PekStoreApi.download(it, onProgress: progress, official: shelf == 'official'),
              padding: c.pek.pagePad,
            ),
          ),
        ),
      ),
    );
    unawaited(check());
  }

  /// Opens the install screen for a GitHub update: the same permissions screen as a first install.
  static Future<void> openGithubUpdate(BuildContext context, GithubUpdate u) async {
    final rel = u.release;
    final opt = rel.options.where((o) => o.kind == u.kind).firstOrNull ?? rel.options.firstOrNull;
    if (opt == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SubScreen(
          title: 'Update ${u.plugin.name}',
          body: Builder(
            builder: (c) => PluginInstallPage(
              title: '${rel.owner}/${rel.repo}',
              shelf: 'github',
              source: {'type': 'github', 'owner': rel.owner, 'repo': rel.repo, 'tag': rel.tag, 'kind': opt.kind},
              load: (_) => PekGithub.download(rel, opt),
              notice: (prep, replaced) => [
                'Update from GitHub: ${rel.owner}/${rel.repo} \u00b7 ${rel.tag}',
                'PEK TV did not make, review or approve it. Check what it asks for before you update.',
              ],
              padding: c.pek.pagePad,
            ),
          ),
        ),
      ),
    );
    unawaited(check());
  }
}

class StoreUpdate {
  const StoreUpdate({required this.plugin, required this.item});
  final PluginInfo plugin; // what is installed now
  final StoreItem item; // the newer version on the store
}

class GithubUpdate {
  const GithubUpdate({required this.plugin, required this.release, required this.kind});
  final PluginInfo plugin;
  final GithubRelease release;
  final String kind;
}
