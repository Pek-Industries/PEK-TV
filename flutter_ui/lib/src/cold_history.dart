import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Cold watch history: the on-device half of the two-tier idea (the cloud does the same in pek-sync/src/archive.js).
///
/// Recent history stays "hot" in [Store] (one small JSON map in SharedPreferences, rewritten on every watch). History that has not changed
/// for a while is moved here: one gzip file per profile and per year (`p1__2025.gz`), which is also the bucket the year-in-review reads.
/// Cold history is only touched when something older is watched again or removed (it is promoted back to hot), when a sync brings newer
/// copies, and when the next batch ages out, so the hot map stays small however long the history gets.
///
/// Rules that keep hot and cold consistent (Store and Cloud rely on them):
///  * if a key is in both, the hot entry is the newer one (or equal);
///  * an entry in a cold file is never pushed to the cloud (it already is there); an entry that comes back newer is promoted to hot first.
///
/// Entries look exactly like the hot ones (`{key, kind, title, year, season, episode, at, count, updated}` or a removal marker
/// `{deleted: 1, updated}`), so [Store] can turn them into `HistoryEntry` the same way.
class ColdHistory {
  static Directory? _dir;

  /// Cold storage needs a folder. Without one (very unlikely) everything keeps working with hot history only.
  static bool get available => _dir != null;

  /// Bumped on every change, so caches in [Store] know to rebuild.
  static int version = 0;

  // profile -> year -> key -> entry
  static final Map<String, Map<String, Map<String, Map<String, dynamic>>>> _mem = {};
  // profile -> key -> year (where a key lives)
  static final Map<String, Map<String, String>> _where = {};

  static Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      await initAt(Directory('${base.path}/history_cold'));
    } catch (_) {
      _dir = null;
    }
  }

  /// Uses [dir] as the folder (tests use a temporary one).
  static Future<void> initAt(Directory dir) async {
    await dir.create(recursive: true);
    _dir = dir;
    _mem.clear();
    _where.clear();
    version++;
  }

  static int _num(dynamic v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);

  static String yearOf(Map<String, dynamic> e) {
    var ms = _num(e['at']);
    if (ms <= 0) ms = _num(e['updated']);
    return '${DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).year}';
  }

  static String _safe(String pid) => pid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  static File _file(String pid, String year) => File('${_dir!.path}/${_safe(pid)}__$year.gz');

  /// Reads a profile's files the first time they are needed (synchronous: it only happens once per profile per app start).
  static void _ensure(String pid) {
    if (_mem.containsKey(pid)) return;
    final years = <String, Map<String, Map<String, dynamic>>>{};
    final where = <String, String>{};
    final dir = _dir;
    if (dir != null) {
      try {
        final prefix = '${_safe(pid)}__';
        for (final f in dir.listSync().whereType<File>()) {
          final name = f.uri.pathSegments.last;
          if (!name.startsWith(prefix) || !name.endsWith('.gz')) continue;
          final year = name.substring(prefix.length, name.length - 3);
          try {
            final o = jsonDecode(utf8.decode(gzip.decode(f.readAsBytesSync())));
            if (o is! Map) continue;
            final m = <String, Map<String, dynamic>>{};
            o.forEach((k, v) {
              if (v is Map) m['$k'] = Map<String, dynamic>.from(v);
            });
            years[year] = m;
            for (final k in m.keys) {
              where[k] = year;
            }
          } catch (_) {
            // an unreadable file is skipped: the cloud still has it and the next sync brings it back
          }
        }
      } catch (_) {}
    }
    _mem[pid] = years;
    _where[pid] = where;
  }

  /// The cold entry for [key] of profile [pid], or null.
  static Map<String, dynamic>? get(String pid, String key) {
    if (!available) return null;
    _ensure(pid);
    final y = _where[pid]![key];
    return y == null ? null : _mem[pid]![y]![key];
  }

  /// Every cold entry (live ones and removal markers) of the profile.
  static Iterable<MapEntry<String, Map<String, dynamic>>> entries(String pid) sync* {
    if (!available) return;
    _ensure(pid);
    for (final m in _mem[pid]!.values) {
      yield* m.entries;
    }
  }

  static int count(String pid) {
    if (!available) return 0;
    _ensure(pid);
    return _where[pid]!.length;
  }

  /// Puts entries into cold storage; an entry only replaces a cold one that is older. Returns how many were stored.
  /// All affected files are written before this returns.
  static int putAll(String pid, Map<String, Map<String, dynamic>> incoming) {
    if (!available || incoming.isEmpty) return 0;
    _ensure(pid);
    final years = _mem[pid]!;
    final where = _where[pid]!;
    final dirty = <String>{};
    var stored = 0;
    incoming.forEach((key, e) {
      final eu = _num(e['updated'] ?? e['at']);
      final oldYear = where[key];
      if (oldYear != null) {
        final old = years[oldYear]![key]!;
        if (_num(old['updated'] ?? old['at']) >= eu) return;
      }
      final y = yearOf(e);
      if (oldYear != null && oldYear != y) {
        years[oldYear]!.remove(key);
        dirty.add(oldYear);
      }
      (years[y] ??= <String, Map<String, dynamic>>{})[key] = Map<String, dynamic>.from(e);
      where[key] = y;
      dirty.add(y);
      stored++;
    });
    for (final y in dirty) {
      _write(pid, y);
    }
    if (stored > 0 || dirty.isNotEmpty) version++;
    return stored;
  }

  static void _write(String pid, String year) {
    final m = _mem[pid]![year];
    final f = _file(pid, year);
    try {
      if (m == null || m.isEmpty) {
        if (f.existsSync()) f.deleteSync();
        _mem[pid]!.remove(year);
        return;
      }
      final tmp = File('${f.path}.tmp');
      tmp.writeAsBytesSync(gzip.encode(utf8.encode(jsonEncode(m))), flush: true);
      tmp.renameSync(f.path); // a crash while writing never leaves a half-written year
    } catch (_) {}
  }

  /// Forgets one profile's cold history (the profile was removed, or the account signed out).
  static void wipe(String pid) {
    _mem.remove(pid);
    _where.remove(pid);
    final dir = _dir;
    if (dir != null) {
      try {
        final prefix = '${_safe(pid)}__';
        for (final f in dir.listSync().whereType<File>()) {
          if (f.uri.pathSegments.last.startsWith(prefix)) f.deleteSync();
        }
      } catch (_) {}
    }
    version++;
  }

  static void wipeAll() {
    _mem.clear();
    _where.clear();
    final dir = _dir;
    if (dir != null) {
      try {
        for (final f in dir.listSync().whereType<File>()) {
          f.deleteSync();
        }
      } catch (_) {}
    }
    version++;
  }
}
