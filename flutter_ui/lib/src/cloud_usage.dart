import 'dart:async';

import 'package:flutter/material.dart';

import 'cloud.dart';
import 'common.dart';
import 'backups_manager.dart';
import 'store.dart';
import 'tokens.dart';

/// What one cloud allowance looks like: [count] of [max] things, using [bytes] (and [maxBytes] when the allowance has a size limit too).
class UsagePart {
  const UsagePart({this.count = 0, this.max = 0, this.bytes = 0, this.maxBytes = 0});
  final int count, max, bytes, maxBytes;

  bool get full => (max > 0 && count >= max) || (maxBytes > 0 && bytes >= maxBytes);

  /// 0..1 for the progress bar: whichever is fuller, the number of items or the space.
  double get fraction {
    final a = max > 0 ? count / max : 0.0;
    final b = maxBytes > 0 ? bytes / maxBytes : 0.0;
    return (a > b ? a : b).clamp(0.0, 1.0);
  }

  factory UsagePart.fromJson(dynamic j) {
    if (j is! Map) return const UsagePart();
    int n(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
    return UsagePart(count: n(j['count']), max: n(j['max']), bytes: n(j['bytes']), maxBytes: n(j['maxBytes']));
  }
}

class UsageSnapshot {
  const UsageSnapshot({required this.profile, required this.plugins, required this.skins});
  final String profile;
  final UsagePart plugins, skins;
}

/// How much of the cloud allowance is used: 30 plugins (60 MB) for the whole account (all profiles share them) and 100 skins for the ACTIVE PROFILE.
///
/// The numbers come from the cloud (`GET /v1/usage?profile=`). Two flags are set by what actually happened, so the warning shows even
/// when the numbers are a little old: [_pluginBlocked] (a plugin upload came back `plugin_quota`) and [_skinBlocked] (a sync came back
/// with `skinsRejected`). Both clear themselves when a later run goes through. Nothing is ever deleted because of a limit: only the
/// backup stops, the plugins and skins stay on the device.
class CloudUsage {
  CloudUsage._();

  static final ValueNotifier<UsageSnapshot?> snapshot = _make();
  static bool _pluginBlocked = false, _skinBlocked = false;
  static int _lastAsk = 0;
  static Future<void>? _asking;

  static ValueNotifier<UsageSnapshot?> _make() {
    final n = ValueNotifier<UsageSnapshot?>(null);
    // Another profile has its own skins: forget the old numbers and ask again (plugins are the same for every profile).
    Store.profile.addListener(() {
      _skinBlocked = false;
      _lastAsk = 0;
      n.value = null;
      if (Cloud.linked) Future<void>.delayed(const Duration(seconds: 2), () => refresh());
    });
    return n;
  }

  static UsageSnapshot? get _mine {
    final s = snapshot.value;
    return s != null && s.profile == Store.profileId ? s : null;
  }

  static UsagePart get plugins => _mine?.plugins ?? const UsagePart(max: 30, maxBytes: 60 * 1024 * 1024);
  static UsagePart get skins => _mine?.skins ?? const UsagePart(max: 100);
  static bool get known => _mine != null;

  static bool get pluginsFull => Cloud.linked && Cloud.entitled && (_pluginBlocked || (known && plugins.full));
  static bool get skinsFull => Cloud.linked && Cloud.entitled && (_skinBlocked || (known && skins.full));

  /// Called by the plugin backup after each pass: [quotaHit] is true when a plugin was refused because the allowance is used up.
  static void notePluginRun({required bool quotaHit}) {
    final _ = snapshot; // makes sure the profile listener exists
    final changed = _pluginBlocked != quotaHit;
    if (changed) {
      _pluginBlocked = quotaHit;
      _bump();
    }
    unawaited(refresh(force: changed));
  }

  /// Called after each sync: [rejected] are the skins the cloud left out because the profile already has 100.
  static void noteSync(List<String> rejected) {
    final _ = snapshot;
    final now = rejected.isNotEmpty;
    final changed = _skinBlocked != now;
    if (changed) {
      _skinBlocked = now;
      _bump();
    }
    unawaited(refresh(force: changed));
  }

  static final ValueNotifier<int> _tick = ValueNotifier(0);
  static void _bump() => _tick.value++;

  /// Everything the banner and the bars listen to.
  static Listenable get listenable => Listenable.merge([snapshot, _tick, Cloud.changes]);

  /// Asks the cloud for this profile's numbers. At most once every 20 seconds unless [force].
  static Future<void> refresh({bool force = false}) {
    if (!Cloud.linked) return Future.value();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_asking != null) return _asking!;
    if (!force && now - _lastAsk < 20000) return Future.value();
    _lastAsk = now;
    final f = _ask().whenComplete(() => _asking = null);
    _asking = f;
    return f;
  }

  static Future<void> _ask() async {
    final pid = Store.profileId;
    try {
      final r = await Cloud.call('GET', '/v1/usage?profile=${Uri.encodeQueryComponent(pid)}');
      if (!r.ok || pid != Store.profileId) return; // signed out, no plan, offline, or the profile changed meanwhile: keep what we had
      final s = UsageSnapshot(profile: pid, plugins: UsagePart.fromJson(r.body['plugins']), skins: UsagePart.fromJson(r.body['skins']));
      // The cloud says there is room again: the "stopped" flags were about an older moment.
      if (!s.plugins.full) _pluginBlocked = false;
      if (!s.skins.full) _skinBlocked = false;
      snapshot.value = s;
      _bump();
    } catch (_) {/* the bars just stay as they were */}
  }

  static String size(int b) => b >= 1048576 ? '${(b / 1048576).toStringAsFixed(b >= 10 * 1048576 ? 0 : 1)} MB' : '${(b / 1024).ceil()} KB';
}

/// One progress bar: "Plugins  12 / 30", the bar, and a line under it (space used, or a warning when it is full).
class UsageBar extends StatelessWidget {
  const UsageBar({super.key, required this.label, required this.part, required this.known, this.detail = '', this.full = false});
  final String label, detail;
  final UsagePart part;
  final bool known, full;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    final near = part.fraction >= 0.8;
    final color = full ? const Color(0xFFDC2626) : (near ? const Color(0xFFD97706) : p.tokens.accent);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(label, style: TextStyle(fontSize: 0.95 * rem, fontWeight: FontWeight.w600))),
        Text(known ? '${part.count} / ${part.max}' : '\u2026', style: TextStyle(fontSize: 0.9 * rem, color: full ? color : p.tokens.textMuted, fontWeight: full ? FontWeight.w700 : FontWeight.w400)),
      ]),
      SizedBox(height: 0.3 * rem),
      ClipRRect(
        borderRadius: BorderRadius.circular(rem),
        child: LinearProgressIndicator(
          value: known ? part.fraction : null,
          minHeight: 0.55 * rem,
          color: color,
          backgroundColor: p.tokens.textMuted.withOpacity(0.18),
        ),
      ),
      if (detail.isNotEmpty || full)
        Padding(
          padding: EdgeInsets.only(top: 0.25 * rem),
          child: Text(full ? 'Full: backup has stopped. ${detail.isEmpty ? '' : detail}'.trim() : detail, style: TextStyle(fontSize: 0.8 * rem, color: full ? color : p.tokens.textMuted)),
        ),
    ]);
  }
}

/// One bar for the Downloads and backups screen: just the plugins (whole account), or just the skins (active profile).
class CloudUsageBar extends StatelessWidget {
  const CloudUsageBar.plugins({super.key}) : skins = false;
  const CloudUsageBar.skins({super.key}) : skins = true;
  final bool skins;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CloudUsage.listenable,
      builder: (context, _) {
        if (!Cloud.linked || !Cloud.entitled) return const SizedBox.shrink();
        final k = CloudUsage.known;
        final part = skins ? CloudUsage.skins : CloudUsage.plugins;
        final left = part.max - part.count < 0 ? 0 : part.max - part.count;
        return Padding(
          padding: EdgeInsets.only(bottom: 0.6 * context.pek.rem),
          child: UsageBar(
            label: skins ? 'Skins in the cloud (this profile)' : 'Plugins in the cloud (all profiles)',
            part: part,
            known: k,
            full: skins ? CloudUsage.skinsFull : CloudUsage.pluginsFull,
            detail: !k ? '' : (skins ? '$left left' : '${CloudUsage.size(part.bytes)} of ${CloudUsage.size(part.maxBytes)} used'),
          ),
        );
      },
    );
  }
}

/// Plugins (whole account) and skins (this profile) bars, Settings > Account.
class CloudUsageCard extends StatefulWidget {
  const CloudUsageCard({super.key});
  @override
  State<CloudUsageCard> createState() => _CloudUsageCardState();
}

class _CloudUsageCardState extends State<CloudUsageCard> {
  @override
  void initState() {
    super.initState();
    unawaited(CloudUsage.refresh(force: true));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    return ListenableBuilder(
      listenable: CloudUsage.listenable,
      builder: (context, _) {
        if (!Cloud.linked || !Cloud.entitled) return const SizedBox.shrink();
        final pl = CloudUsage.plugins, sk = CloudUsage.skins, k = CloudUsage.known;
        return Padding(
          padding: EdgeInsets.only(top: 0.9 * rem),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Cloud storage', style: TextStyle(fontSize: rem, fontWeight: FontWeight.w700)),
            SizedBox(height: 0.2 * rem),
            Text('Plugins are shared by every profile. Each profile has its own skins and its own skin limit.', style: TextStyle(fontSize: 0.8 * rem, color: p.tokens.textMuted)),
            SizedBox(height: 0.6 * rem),
            UsageBar(label: 'Plugins', part: pl, known: k, full: CloudUsage.pluginsFull, detail: k ? '${CloudUsage.size(pl.bytes)} of ${CloudUsage.size(pl.maxBytes)} used' : ''),
            SizedBox(height: 0.7 * rem),
            UsageBar(label: 'Skins', part: sk, known: k, full: CloudUsage.skinsFull, detail: k ? '${sk.max - sk.count < 0 ? 0 : sk.max - sk.count} left' : ''),
          ]),
        );
      },
    );
  }
}

/// The banner across the top of the app while the active profile's cloud plugin or skin allowance is used up: backup of those has stopped
/// until something is removed. Amber, one button to the screen where things are removed, an X to hide it until the app starts again
/// (or until the situation changes, e.g. skins were already full and now plugins are too).
class BackupLimitBanner {
  BackupLimitBanner._();

  static final ValueNotifier<String> _hidden = ValueNotifier('');

  static String _state() {
    final a = CloudUsage.pluginsFull, b = CloudUsage.skinsFull;
    return a && b ? 'both' : (a ? 'plugins' : (b ? 'skins' : ''));
  }

  /// Puts the banner above [child]. Same tree shape with and without the banner, so the pages below keep their state.
  static Widget wrap({required Widget child}) => ListenableBuilder(
        listenable: Listenable.merge([CloudUsage.listenable, _hidden, Store.profile]),
        builder: (context, _) {
          final state = _state();
          final show = state.isNotEmpty && _hidden.value != '${Store.profileId}:$state';
          return Column(
            children: [
              if (show) _bar(context, state) else const SizedBox.shrink(),
              Expanded(child: MediaQuery.removePadding(context: context, removeTop: show, child: child)),
            ],
          );
        },
      );

  static Widget _bar(BuildContext context, String state) {
    final p = context.pek;
    final rem = p.rem;
    final what = state == 'both' ? 'plugins and skins' : state;
    final limit = state == 'both'
        ? 'You have reached the limit of 30 plugins and 100 skins.'
        : state == 'plugins'
            ? 'You have reached the limit of 30 plugins (or 60 MB).'
            : 'You have reached the limit of 100 skins.';
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Cloud backup of your $what has stopped', style: TextStyle(fontSize: 1.0 * rem, fontWeight: FontWeight.w800, color: Colors.white)),
        SizedBox(height: 0.15 * rem),
        Text('$limit Remove ${state == 'both' ? 'some' : 'a few'} $what from your cloud backup to start backing up again. Nothing is deleted from this device.', style: TextStyle(fontSize: 0.85 * rem, color: Colors.white)),
      ],
    );
    final action = TextButton(
      style: TextButton.styleFrom(foregroundColor: const Color(0xFF92400E), backgroundColor: Colors.white, padding: EdgeInsets.symmetric(horizontal: 1.0 * rem, vertical: 0.4 * rem)),
      onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => SubScreen(
          title: 'Downloads and backups',
          body: Builder(builder: (c) => ListView(padding: c.pek.pagePad, children: const [BackupsSection()])),
        ),
      )),
      child: Text('Manage', style: TextStyle(fontSize: 0.85 * rem, fontWeight: FontWeight.w800)),
    );
    final close = IconButton(
      tooltip: 'Hide until the app restarts',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.close, color: Colors.white),
      onPressed: () => _hidden.value = '${Store.profileId}:$state',
    );
    final top = p.sidebar ? p.safeY : MediaQuery.paddingOf(context).top;
    return Container(
      width: double.infinity,
      color: const Color(0xFFB45309),
      padding: EdgeInsets.fromLTRB(rem + (p.sidebar ? p.safeX : 0), top + 0.6 * rem, 0.4 * rem, 0.6 * rem),
      child: p.sidebar
          ? Row(children: [
              const Icon(Icons.cloud_off_rounded, color: Colors.white),
              SizedBox(width: 0.8 * rem),
              Expanded(child: text),
              SizedBox(width: rem),
              action,
              close,
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.cloud_off_rounded, color: Colors.white)),
                SizedBox(width: 0.7 * rem),
                Expanded(child: text),
                close,
              ]),
              SizedBox(height: 0.4 * rem),
              Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(left: 2 * rem), child: action)),
            ]),
    );
  }
}
