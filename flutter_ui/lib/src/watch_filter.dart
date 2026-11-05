import 'package:flutter/material.dart';

import 'api.dart';
import 'detail.dart' show episodeWatched, movieWatched;
import 'store.dart';
import 'tokens.dart';
import 'tv_nav.dart';
import 'widgets.dart';

/// Which titles a list shows, by how far you are with them.
enum WatchFilter {
  all('All'),
  unwatched('Unwatched'),
  watching('Watching'),
  watched('Watched');

  const WatchFilter(this.label);
  final String label;
}

/// The ids of everything that is stopped partway (what Resume Watching lists). Read once per build, then handed to
/// [movieStatus] / [showStatus]: asking the store for every episode on its own would decode the saved progress each time.
Set<String> resumeIds() => {for (final r in Store.resumeItems()) r.id};

/// Watched = in Watch History; Watching = stopped partway (not finished); Unwatched = neither.
WatchFilter movieStatus(Movie m, Set<String> resuming) {
  if (movieWatched(m)) return WatchFilter.watched;
  if (resuming.contains(m.id)) return WatchFilter.watching;
  return WatchFilter.unwatched;
}

/// Watched = every episode is in Watch History; Watching = some episodes watched or one stopped partway; else Unwatched.
WatchFilter showStatus(Show s, Set<String> resuming) {
  var total = 0, seen = 0;
  var partial = false;
  for (final se in s.seasons) {
    for (final e in se.episodes) {
      total++;
      if (episodeWatched(s, e)) {
        seen++;
      } else if (resuming.contains(e.id)) {
        partial = true;
      }
    }
  }
  if (total > 0 && seen == total) return WatchFilter.watched;
  if (seen > 0 || partial) return WatchFilter.watching;
  return WatchFilter.unwatched;
}

/// A row of filter buttons (the selected one is filled), each with its count when [counts] is given. One tap switches; the D-pad moves along it like any row.
class WatchFilterBar extends StatelessWidget {
  const WatchFilterBar({super.key, required this.value, required this.onChanged, this.options = WatchFilter.values, this.counts});
  final WatchFilter value;
  final ValueChanged<WatchFilter> onChanged;
  final List<WatchFilter> options;

  /// How many titles each button would show ("Watching 4"); null = no numbers.
  final Map<WatchFilter, int>? counts;

  @override
  Widget build(BuildContext context) {
    final rem = context.pek.rem;
    return TvNav.region(
      memoryKey: 'watch-filter',
      child: Wrap(spacing: 0.6 * rem, runSpacing: 0.5 * rem, children: [
        for (final f in options) PekButton(compact: true, label: counts?[f] == null ? f.label : '${f.label} ${counts![f]}', primary: f == value, onTap: () => onChanged(f)),
      ]),
    );
  }
}
