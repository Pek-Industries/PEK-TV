import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:http/http.dart' as http;

import 'activity.dart';

import 'api.dart';
import 'common.dart';
import 'fields.dart';
import 'player.dart';
import 'plugin_host.dart' show PluginHost;
import 'plugin_ui.dart' show openPluginScreen;
import 'recs.dart' show RecFeed;
import 'store.dart';
import 'tokens.dart';
import 'widgets.dart';

/// What the C++ server says about one running torrent (GET /api/torrent/<hash>/status).
class TorrentStatus {
  const TorrentStatus({
    required this.state,
    required this.ready,
    required this.file,
    required this.error,
    required this.peers,
    required this.downKBps,
    required this.bufferProgress,
    required this.fileSize,
  });
  final String state; // 'metadata' | 'downloading' | 'error' ...
  final bool ready;
  final String file;
  final String error;
  final int peers;
  final int downKBps;
  final double bufferProgress; // 0..1, how much of the play-ahead window is downloaded
  final int fileSize;

  factory TorrentStatus.fromJson(Map<String, dynamic> j) => TorrentStatus(
        state: '${j['state'] ?? ''}',
        ready: j['ready'] == true,
        file: '${j['file'] ?? ''}',
        error: '${j['error'] ?? ''}',
        peers: (j['peers'] as num?)?.toInt() ?? 0,
        downKBps: (j['downKBps'] as num?)?.toInt() ?? 0,
        bufferProgress: (j['bufferProgress'] as num?)?.toDouble() ?? 0,
        fileSize: (j['fileSize'] as num?)?.toInt() ?? 0,
      );

  static String speed(int kb) => kb >= 1024 ? '${(kb / 1024).toStringAsFixed(1)} MB/s' : '$kb KB/s';

  /// "42%  \u00b7 12 peers \u00b7 3.2 MB/s"
  String get line => '${(bufferProgress * 100).round()}% \u00b7 $peers peer${peers == 1 ? '' : 's'} \u00b7 ${speed(downKBps)}';
}

/// The torrent routes of the existing backend (backend/torrent_routes.cpp). Nothing in the backend changes.
class TorrentApi {
  static final http.Client _c = http.Client();

  static Future<bool> available() async {
    try {
      final r = await _c.get(Uri.parse('${Api.base}/api/torrent/info')).timeout(const Duration(seconds: 5));
      final o = jsonDecode(r.body);
      return o is Map && o['available'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Starts the torrent and returns its hash. A pasted https .torrent link is vouched for first (the server only downloads
  /// .torrent files it was told about); a magnet link needs nothing.
  ///
  /// The server only starts a torrent for a request that carries a [grant] (backend/torrent_routes.cpp), and a grant only comes
  /// from [_streamGrant], which only hands one out for a stream a plugin is behind.
  static Future<String> start(String source, {int season = 0, int episode = 0, required String grant}) async {
    final h0 = {'X-Pek-Grant': grant};
    if (!source.startsWith('magnet:?')) {
      await Api.postForm('/api/torrent/allow', {'url': source}, headers: h0);
    }
    final j = await Api.postForm('/api/torrent/start', {'source': source, 'season': '$season', 'episode': '$episode'}, headers: h0);
    final h = '${j['hash'] ?? ''}';
    if (h.isEmpty) throw ApiError('Could not start the torrent.');
    return h;
  }

  static Future<TorrentStatus> status(String hash) async {
    final r = await _c.get(Uri.parse('${Api.base}/api/torrent/$hash/status')).timeout(const Duration(seconds: 10));
    final o = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode != 200 || o is! Map) {
      throw ApiError(o is Map && o['error'] != null ? '${o['error']}' : 'The torrent is gone.');
    }
    return TorrentStatus.fromJson(Map<String, dynamic>.from(o));
  }

  /// Stops the torrent and deletes its temporary data.
  static Future<void> stop(String hash) async {
    try {
      await _c.post(Uri.parse('${Api.base}/api/torrent/$hash/stop')).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  static String streamUrl(String hash) => '${Api.base}/api/torrent/$hash/stream';
}

/// What to remember for Resume Watching and how to start a pasted release again.
class TorrentTitle {
  const TorrentTitle({required this.kind, required this.title, this.showTitle = '', this.year = 0, this.season = 0, this.episode = 0, this.tmdb = 0});
  final String kind; // 'movie' | 'episode' | 'other'
  final String title; // what the player shows
  final String showTitle;
  final int year;
  final int season;
  final int episode;
  final int tmdb; // the title's TMDb id when a plugin knew it (0 = unknown); "Up next" uses it to reopen the right show

  static String _clean(String s) => s.replaceAll(RegExp(r'[._]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'[\s\-(\[]+$'), '').trim();

  /// The name inside a magnet link (`dn=`), or ''.
  static String nameOf(String source) {
    final m = RegExp(r'[?&]dn=([^&]+)', caseSensitive: false).firstMatch(source);
    if (m == null) return '';
    try {
      return Uri.decodeComponent(m.group(1)!.replaceAll('+', ' '));
    } catch (_) {
      return m.group(1)!;
    }
  }

  /// "Some.Show.S02E05.1080p..." -> episode; "Some.Movie.2019.1080p..." -> movie; anything else stays "other".
  static TorrentTitle parse(String raw, {String fallback = 'Torrent'}) {
    final name = raw.trim();
    if (name.isEmpty) return TorrentTitle(kind: 'other', title: fallback);
    final ep = RegExp(r'^(.*?)[\s._\-]+S(\d{1,2})[\s._\-]?E(\d{1,3})', caseSensitive: false).firstMatch(name);
    if (ep != null && _clean(ep.group(1)!).isNotEmpty) {
      final show = _clean(ep.group(1)!);
      final s = int.parse(ep.group(2)!), e = int.parse(ep.group(3)!);
      String two(int n) => n.toString().padLeft(2, '0');
      return TorrentTitle(kind: 'episode', title: '$show S${two(s)}E${two(e)}', showTitle: show, season: s, episode: e);
    }
    final mv = RegExp(r'^(.*?)[\s._(\[\-]+((?:19|20)\d\d)(?!\d)').firstMatch(name);
    if (mv != null && _clean(mv.group(1)!).isNotEmpty) {
      return TorrentTitle(kind: 'movie', title: _clean(mv.group(1)!), year: int.parse(mv.group(2)!));
    }
    return TorrentTitle(kind: 'other', title: _clean(name).isEmpty ? fallback : _clean(name));
  }

  /// The Resume Watching entry for this release (its id is the same one the cloud and other devices use for torrents).
  Progress track(String source, {String origin = 'Torrent', String image = ''}) {
    final key = Store.keyFor(kind: kind, title: title, showTitle: showTitle, year: year, season: season, episode: episode) ?? 'o|${Store.normalize(title)}|0|0';
    return Progress(
      id: 'tor:$key',
      title: title,
      kind: kind,
      position: 0,
      duration: 0,
      updated: 0,
      showTitle: showTitle,
      year: year,
      season: season,
      episode: episode,
      torrent: {'source': source, 'title': title, 'season': season, 'episode': episode, if (tmdb > 0) 'tmdb': tmdb},
      origin: origin,
      image: image,
    );
  }
}

/// Starts a torrent behind a loading screen and opens the player when enough is downloaded.
///
/// PEK itself never starts a torrent on its own: a release only plays when a plugin (Stream Media and the like) fed it in.
/// - [pluginId] set: a plugin screen that is open right now handed the release over (the "torrent.play" effect).
/// - not set: a saved entry is being replayed (Resume Watching, Watch History, another device). It only plays while the plugin
///   that started it ([Progress.origin]) is still installed and can stream; a pasted link, a search of PEK's own, a stream whose
///   plugin was removed (or never installed on this device) does not start, and the person is told to install the plugin.
Future<void> playTorrent(BuildContext context, {required Progress track, double startSec = 0, String? pluginId}) async {
  final t = track.torrent;
  if (t == null) return;
  if (!await _mayStream(track, pluginId)) {
    if (context.mounted) await _noPluginDialog(context, track);
    return;
  }
  if (!context.mounted) return;
  final label = track.title.length > 40 ? track.title.substring(0, 40) : track.title;
  Activity.note('Starting stream${label.isEmpty ? '' : ': $label'}\u2026');
  await Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => TorrentLoadingScreen(track: track, startSec: startSec, pluginId: pluginId)));
}

/// Whether a plugin is behind this stream: the open plugin screen that handed it over ([pluginId]), or, for a saved entry,
/// an installed plugin that can stream and is the one that started it.
Future<bool> _mayStream(Progress track, String? pluginId) async {
  if (pluginId != null && pluginId.isNotEmpty) return true;
  if (PluginHost.streamers == null) await PluginHost.refreshStreamers();
  return (PluginHost.streamers ?? const <Map<String, String>>[]).any((e) => e['id'] == track.origin && e['stream'] == 'true');
}

/// The pass the torrent server wants before it starts a stream, or null when no plugin is behind this one. The pass comes from
/// the app's own native side (not from an HTTP route), so only this code path can get one.
Future<String?> _streamGrant(Progress track, String? pluginId) async {
  if (!await _mayStream(track, pluginId)) return null;
  try {
    final g = await const MethodChannel('pek/host').invokeMethod<String>('torrentGrant');
    return g == null || g.isEmpty ? null : g;
  } catch (_) {
    return null;
  }
}

/// A saved stream that no installed plugin can play: the progress is kept (Resume Watching and the cloud still have it), and
/// the person can open the title in TMDb Discover, which ships with PEK, and play it with whatever plugin they install.
Future<void> _noPluginDialog(BuildContext context, Progress track) async {
  final open = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('No plugin can play this'),
      content: Text('\u201c${track.title}\u201d was started from a plugin, and no installed plugin can play it now. Your progress is saved. You can open it in TMDb Discover and play it from there once a video plugin is installed.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(autofocus: true, onPressed: () => Navigator.pop(c, true), child: const Text('Open in TMDb Discover')),
      ],
    ),
  );
  if (open != true || !context.mounted) return;
  final tv = track.kind == 'episode';
  final name = tv ? track.showTitle : track.title.replaceAll(RegExp(r'\s*\(\d{4}\)\s*$'), '');
  var id = (track.torrent?['tmdb'] as num?)?.toInt() ?? 0;
  if (id <= 0) id = tv ? await RecFeed.tvIdByName(name) : await RecFeed.movieIdByName(name, year: track.year);
  if (!context.mounted) return;
  if (id <= 0) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Could not find this title on TMDb.')));
    return;
  }
  await openPluginScreen(context, pluginId: 'tmdb-discover', title: 'TMDb Discover', launch: {'type': tv ? 'tv' : 'movie', 'id': id, 'title': name, 'year': tv ? 0 : track.year});
}

/// The "starting stream" box of torrent.js: contacts the swarm, shows how far the loading is, opens the player when ready.
class TorrentLoadingScreen extends StatefulWidget {
  const TorrentLoadingScreen({super.key, required this.track, this.startSec = 0, this.pluginId});
  final Progress track;
  final double startSec;
  final String? pluginId; // the plugin screen that handed the release over; null for a saved entry
  @override
  State<TorrentLoadingScreen> createState() => _TorrentLoadingScreenState();
}

class _TorrentLoadingScreenState extends State<TorrentLoadingScreen> {
  static const _noMetadata = Duration(seconds: 90);
  static const _noPeers = Duration(seconds: 120);

  String _line = 'Contacting the swarm\u2026';
  double _frac = 0.03;
  String? _error;
  bool _cancelled = false;
  bool _opened = false;
  String _hash = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final t = widget.track.torrent!;
    try {
      final grant = await _streamGrant(widget.track, widget.pluginId);
      if (grant == null) throw ApiError('This stream plays through the plugin that started it. Install that plugin to watch it.');
      _hash = await TorrentApi.start('${t['source']}', season: (t['season'] as num?)?.toInt() ?? 0, episode: (t['episode'] as num?)?.toInt() ?? 0, grant: grant);
      if (_cancelled) {
        unawaited(TorrentApi.stop(_hash));
        return;
      }
      final t0 = DateTime.now();
      var lastGood = DateTime.now();
      for (;;) {
        if (_cancelled || !mounted) return;
        final s = await TorrentApi.status(_hash);
        if (_cancelled || !mounted) return;
        if (s.state == 'error') throw ApiError(s.error.isEmpty ? 'The torrent failed.' : s.error);
        if (s.state == 'metadata') {
          setState(() {
            _line = 'Getting the file list\u2026 (${s.peers} peers)';
            _frac = 0.05;
          });
          if (DateTime.now().difference(t0) > _noMetadata) throw ApiError('Couldn\u2019t get this torrent\u2019s file list. It may have no seeders.');
        } else if (s.ready) {
          break;
        } else {
          if (s.peers > 0 || s.downKBps > 0) lastGood = DateTime.now();
          setState(() {
            _line = 'Loading ${s.line}${s.file.isEmpty ? '' : '\n${s.file}'}${s.fileSize > 0 ? '\n${formatBytes(s.fileSize)}' : ''}';
            _frac = 0.1 + 0.9 * s.bufferProgress;
          });
          if (DateTime.now().difference(lastGood) > _noPeers) throw ApiError('No one is sending data for this release. Try another one.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (_cancelled || !mounted) {
        unawaited(TorrentApi.stop(_hash));
        return;
      }
      _opened = true;
      final hash = _hash;
      unawaited(PluginHost.refreshStreamers()); // the Up next card is only offered while the plugin that started this is installed
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            url: TorrentApi.streamUrl(hash),
            title: widget.track.title,
            startSec: widget.startSec,
            resume: widget.track,
            nextFor: _nextFromPlugin,
            torrentHash: hash,
            onClose: () => unawaited(TorrentApi.stop(hash)),
          ),
        ),
      );
    } catch (e) {
      if (_hash.isNotEmpty) unawaited(TorrentApi.stop(_hash));
      if (mounted && !_cancelled) setState(() => _error = e is ApiError ? e.message : 'Could not start this torrent.');
    }
  }

  /// "Up next" for an episode a plugin (Stream Media) started: the same show's next episode. Accepting it opens that plugin on the
  /// episode and it finds the best stream itself, so this only says which episode and which plugin. A pasted release (no plugin) gets none.
  static Progress? _nextFromPlugin(Progress cur) {
    final t = cur.torrent;
    if (t == null || cur.kind != 'episode' || cur.season <= 0 || cur.episode <= 0 || cur.showTitle.isEmpty) return null;
    final streamers = PluginHost.streamers ?? const <Map<String, String>>[];
    if (!streamers.any((e) => e['id'] == cur.origin && e['stream'] == 'true')) return null;
    final ep = cur.episode + 1;
    String two(int n) => n.toString().padLeft(2, '0');
    return Progress(
      id: 'tor:next:${cur.showTitle}|${cur.season}|$ep',
      title: '${cur.showTitle} S${two(cur.season)}E${two(ep)}',
      kind: 'episode',
      position: 0,
      duration: 0,
      updated: 0,
      showTitle: cur.showTitle,
      season: cur.season,
      episode: ep,
      torrent: {'source': '', 'title': '${cur.showTitle} S${two(cur.season)}E${two(ep)}', 'season': cur.season, 'episode': ep, 'next': true, if (((cur.torrent?['tmdb'] as num?)?.toInt() ?? 0) > 0) 'tmdb': (cur.torrent!['tmdb'] as num).toInt()},
      origin: cur.origin,
      image: cur.image,
    );
  }

  void _cancel() {
    _cancelled = true;
    if (_hash.isNotEmpty) unawaited(TorrentApi.stop(_hash));
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    // Left without the player taking over (Back, an error): the temporary data goes.
    if (!_opened && _hash.isNotEmpty) {
      _cancelled = true;
      unawaited(TorrentApi.stop(_hash));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelled = true;
      },
      child: Scaffold(
        backgroundColor: t.bg,
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(1.5 * rem),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 28 * rem),
              child: Container(
                padding: EdgeInsets.all(1.5 * rem),
                decoration: BoxDecoration(color: t.glassStrong, borderRadius: BorderRadius.circular(t.radius), border: Border.all(color: t.border)),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.track.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 1.25 * rem, fontWeight: FontWeight.w700)),
                  SizedBox(height: 0.75 * rem),
                  if (_error != null)
                    Text(_error!, style: const TextStyle(color: Colors.redAccent))
                  else ...[
                    Text(_line, style: TextStyle(color: t.textMuted)),
                    SizedBox(height: 0.9 * rem),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(value: _frac.clamp(0.03, 1.0), minHeight: 0.5 * rem, color: t.accent, backgroundColor: t.surface),
                    ),
                  ],
                  SizedBox(height: 1.25 * rem),
                  PekButton(label: _error != null ? 'Close' : 'Cancel', autofocus: true, onTap: _cancel),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown in the middle of the player while a torrent stream is buffering (for example right after scrubbing): how far the
/// loading is, how many peers and how fast. Only polls while it is on screen.
class TorrentBufferCard extends StatefulWidget {
  const TorrentBufferCard({super.key, required this.hash});
  final String hash;
  @override
  State<TorrentBufferCard> createState() => _TorrentBufferCardState();
}

class _TorrentBufferCardState extends State<TorrentBufferCard> {
  TorrentStatus? _s;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _poll();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final s = await TorrentApi.status(widget.hash);
      if (mounted) setState(() => _s = s);
    } catch (_) {}
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(14)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 34, height: 34, child: CircularProgressIndicator(strokeWidth: 3)),
        const SizedBox(height: 10),
        const Text('Loading\u2026', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        if (s != null) ...[
          const SizedBox(height: 4),
          Text(s.line, style: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 13)),
        ],
        if (s != null) ...[
          const SizedBox(height: 8),
          SizedBox(width: 180, child: LinearProgressIndicator(value: s.bufferProgress.clamp(0.0, 1.0), minHeight: 4, color: Colors.white, backgroundColor: const Color(0x44FFFFFF))),
        ],
      ]),
    );
  }
}
