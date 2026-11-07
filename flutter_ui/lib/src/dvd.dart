import 'package:flutter/material.dart';

import 'player.dart';
import 'store.dart' show Progress;

/// One title of a DVD (what the disc's own title table lists). [n] is the number libmpv's `dvd://<n>` takes.
class DvdTitle {
  const DvdTitle({required this.n, required this.seconds, required this.chapters, required this.angles});
  final int n;
  final int seconds; // 0 = the disc did not say
  final int chapters;
  final int angles;

  String get length {
    if (seconds <= 0) return '';
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  String get detail {
    final parts = <String>[
      if (length.isNotEmpty) length,
      if (chapters > 0) '$chapters chapter${chapters == 1 ? '' : 's'}',
      if (angles > 1) '$angles angles',
    ];
    return parts.join(' · ');
  }
}

/// What GET /api/dvd/<id> says about a library item that is a DVD (backend/dvd_info.h).
class DvdInfo {
  const DvdInfo({
    required this.device,
    required this.iso,
    required this.detailsKnown,
    required this.hasMenu,
    required this.hasTitleMenus,
    required this.main,
    required this.titles,
  });

  final String device; // the folder holding VIDEO_TS, or the .iso: what the player opens
  final bool iso;
  final bool detailsKnown; // false: it is a DVD, but its tables could not be read (no title list)
  final bool hasMenu; // the disc has its own main menu
  final bool hasTitleMenus;
  final int main; // the longest title (1-based), 0 = unknown
  final List<DvdTitle> titles;

  factory DvdInfo.fromJson(Map<String, dynamic> j) {
    int i(dynamic v) => (v as num?)?.toInt() ?? 0;
    final list = <DvdTitle>[];
    final raw = j['titles'];
    if (raw is List) {
      for (final t in raw) {
        if (t is Map) list.add(DvdTitle(n: i(t['n']), seconds: i(t['seconds']), chapters: i(t['chapters']), angles: i(t['angles'])));
      }
    }
    return DvdInfo(
      device: '${j['device'] ?? ''}',
      iso: j['iso'] == true,
      detailsKnown: j['detailsKnown'] == true,
      hasMenu: j['hasMenu'] == true,
      hasTitleMenus: j['hasTitleMenus'] == true,
      main: i(j['main']),
      titles: list,
    );
  }

  /// Titles worth listing: a few seconds long are menu stills / FBI warnings. Unknown lengths are kept.
  List<DvdTitle> get listed => titles.where((t) => t.seconds <= 0 || t.seconds >= 15).toList();

  /// Ask what to play? Only when there is something to choose: an original menu, or more than one real title.
  bool get needsPicker => detailsKnown && (hasMenu || hasTitleMenus || listed.length > 1);
}

/// Plays a DVD. A disc with a menu or several titles first asks what to play (the disc's own menu can not be shown by this
/// libmpv build, so the title list is the menu); pressing Continue on something already started goes straight back to the film.
Future<void> playDvd(BuildContext context, Progress item, DvdInfo dvd, {double startSec = 0}) async {
  var title = dvd.main; // 0 = libmpv picks the longest title itself
  if (startSec <= 0 && dvd.needsPicker) {
    final picked = await chooseDvdTitle(context, dvd, item.title);
    if (picked == null) return;
    title = picked;
  }
  if (!context.mounted) return;
  final isMain = title == dvd.main;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        url: title > 0 ? 'dvd://$title' : 'dvd://',
        title: isMain ? item.title : '${item.title} - title $title',
        startSec: isMain ? startSec : 0, // a resume point belongs to the film, not to an extra
        resume: isMain ? item : null,
        dvdDevice: dvd.device,
      ),
    ),
  );
}

/// The disc menu replacement: "Play movie" and the list of titles. Returns the title number (0 = let the player choose), null = cancelled.
Future<int?> chooseDvdTitle(BuildContext context, DvdInfo dvd, String name) {
  final main = dvd.titles.where((t) => t.n == dvd.main).firstOrNull;
  final others = dvd.listed.where((t) => t.n != dvd.main).toList();
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            ListTile(
              title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: Text(
                dvd.hasMenu
                    ? 'This DVD has its own menu. The original menu cannot be shown yet, so choose what to play here.'
                    : 'DVD${dvd.iso ? ' image' : ''}',
              ),
            ),
            ListTile(
              autofocus: true,
              leading: const Icon(Icons.play_arrow),
              title: const Text('Play movie'),
              subtitle: main == null || main.detail.isEmpty ? null : Text(main.detail),
              onTap: () => Navigator.pop(ctx, dvd.main),
            ),
            if (others.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Other titles on the disc', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            for (final t in others)
              ListTile(
                leading: const Icon(Icons.movie_outlined),
                title: Text('Title ${t.n}'),
                subtitle: t.detail.isEmpty ? null : Text(t.detail),
                onTap: () => Navigator.pop(ctx, t.n),
              ),
          ],
        ),
      ),
    ),
  );
}
