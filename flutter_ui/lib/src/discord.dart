import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cloud.dart';
import 'store.dart';

/// One run of "link my Discord": a link to open (a phone opens it, a TV shows it as a QR code), the secret to poll with, and
/// which profile it is for (the profile that was open when it started keeps the link, even if another is opened meanwhile).
class DiscordLinkSession {
  const DiscordLinkSession({required this.url, required this.poll, required this.profile, required this.expiresAt, required this.interval});
  final String url;
  final String poll;
  final String profile;
  final int expiresAt; // ms since epoch
  final int interval; // seconds between polls
}

/// Discord Rich Presence: shows "Watching <title>" on the person's Discord profile while something plays (see DISCORD.md).
///
/// How it fits together:
///  - Linking. The person approves PEK TV on Discord's own page; the PEK cloud worker (/v1/discord/*) keeps the
///    client secret, swaps the code for tokens and hands them to this device once. A phone opens the link in its browser or
///    the Discord app, a TV shows it as a QR code (the same idea as "Sign in with your phone").
///  - Presence. The tokens go to the native side (`pek/discord` channel, FlutterDiscord.kt -> discord_presence.cpp -> the Discord
///    Social SDK), which connects as that person and sets the activity. Nothing about what is playing goes to the PEK cloud.
///  - What is shown. [playback] is called from PluginHooks.playback, which only reports movies and episodes with a title
///    (a torrent with no identity is never reported). With "Show titles" off the profile only says "Watching on PEK TV".
///
/// Each profile has its own link: it is kept under the key `pek_discord_<profile id>`, device-wide (never in the synced,
/// profile-scoped keys), so a Discord token never leaves this device through PEK Cloud sync.
class DiscordPresence {
  static const _ch = MethodChannel('pek/discord');

  /// Bumped whenever the link or a setting changes, so the settings section repaints.
  static final ValueNotifier<int> changed = ValueNotifier(0);

  static bool? _available;
  static bool _started = false;
  static Future<void>? _syncing;
  static bool _again = false;
  static String _connectedProfile = ''; // whose token the native side holds right now
  static String _connectedToken = '';

  // ---------------------------------------------------------------------------------------------- what is stored

  static String _key(String profile) => 'pek_discord_$profile';

  static Map<String, dynamic> _read(String profile) {
    final raw = Store.strGet(_key(profile), scoped: false);
    if (raw == null || raw.isEmpty) return {};
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : {};
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(String profile, Map<String, dynamic> m) async {
    if (m.isEmpty) {
      await Store.strDel(_key(profile), scoped: false);
    } else {
      await Store.strSet(_key(profile), jsonEncode(m), scoped: false);
    }
    changed.value++;
  }

  /// This profile has a Discord account linked.
  static bool get linked => '${_read(Store.profileId)['access'] ?? ''}'.isNotEmpty;

  /// Signed in to PEK, Discord linked and not switched off: what is playing goes to Discord. (Signing out of PEK stops it; the
  /// Discord link stays on the device and works again after signing back in.)
  static bool get showing => Cloud.linked && linked && _read(Store.profileId)['on'] != false;

  /// False = Discord only says "Watching on PEK TV".
  static bool get showTitles => _read(Store.profileId)['titles'] != false;

  static Future<void> setShowing(bool on) async {
    final m = _read(Store.profileId);
    if (m.isEmpty) return;
    m['on'] = on;
    await _write(Store.profileId, m);
    if (on) {
      unawaited(_sync());
    } else {
      await _disconnect();
    }
  }

  static Future<void> setShowTitles(bool on) async {
    final m = _read(Store.profileId);
    if (m.isEmpty) return;
    m['titles'] = on;
    await _write(Store.profileId, m);
    _lastSent = ''; // what is shown right now is redrawn with the next event
  }

  // ---------------------------------------------------------------------------------------------- native side

  /// False when this build has no Discord Social SDK (DISCORD.md, step 4) or the channel is missing: the settings say so and
  /// nothing else in the app changes.
  static Future<bool> available() async {
    final known = _available;
    if (known != null) return known;
    try {
      _available = (await _ch.invokeMethod<bool>('available').timeout(const Duration(seconds: 3))) ?? false;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// The answer of [available] once it is known (null until then).
  static bool? get knownAvailable => _available;

  /// `off`, `connecting`, `ready` or `error`, for the settings line.
  static Future<String> status() async {
    try {
      return (await _ch.invokeMethod<String>('status')) ?? 'off';
    } catch (_) {
      return 'off';
    }
  }

  /// Opens a link in the phone's browser (or the Discord app, which takes Discord links itself).
  static Future<bool> openUrl(String url) async {
    try {
      return (await _ch.invokeMethod<bool>('openUrl', {'url': url})) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _disconnect() async {
    _connectedProfile = '';
    _connectedToken = '';
    _lastSent = '';
    try {
      await _ch.invokeMethod<void>('disconnect');
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------------------------- start / profiles / tokens

  /// Once per run (from the shell, with the plugin hooks): connects if this profile is linked, and follows profile changes.
  static void start() {
    if (_started) return;
    _started = true;
    Store.profile.addListener(_profileChanged);
    Cloud.changes.addListener(() => unawaited(_sync())); // signing out of PEK stops Discord presence, signing in resumes it
    unawaited(_sync());
  }

  static void _profileChanged() {
    // The next person's Discord must never show what the last one was watching.
    unawaited(() async {
      try {
        await _ch.invokeMethod<void>('clear');
      } catch (_) {}
      _lastSent = '';
      await _sync();
    }());
  }

  /// Makes the native side hold this profile's token (refreshing it first if it is about to run out), or nothing if the profile
  /// has no link or has it switched off. Cheap when nothing changed.
  static Future<void> _sync() {
    final running = _syncing;
    if (running != null) {
      _again = true; // something changed while a sync was running: it goes round once more
      return running;
    }
    final f = () async {
      do {
        _again = false;
        await _syncOnce();
      } while (_again);
    }()
        .whenComplete(() => _syncing = null);
    _syncing = f;
    return f;
  }

  static Future<void> _syncOnce() async {
    try {
      if (!await available()) return;
      final pid = Store.profileId;
      if (!showing) {
        if (_connectedProfile.isNotEmpty) await _disconnect();
        return;
      }
      await _refreshIfDue(pid);
      final m = _read(pid);
      final token = '${m['access'] ?? ''}';
      final app = '${m['app'] ?? ''}';
      if (token.isEmpty || app.isEmpty) {
        if (_connectedProfile.isNotEmpty) await _disconnect();
        return;
      }
      if (_connectedProfile == pid && _connectedToken == token) return;
      _lastSent = ''; // a new connection starts with nothing shown: the next playback event must go out
      await _ch.invokeMethod<void>('connect', {'appId': app, 'token': token});
      _connectedProfile = pid;
      _connectedToken = token;
    } catch (_) {
      // Discord being unreachable never breaks playback
    }
  }

  static const _refreshBefore = Duration(hours: 24);

  static Future<void> _refreshIfDue(String pid) async {
    final m = _read(pid);
    final refresh = '${m['refresh'] ?? ''}';
    final exp = (m['exp'] as num?)?.toInt() ?? 0;
    if (refresh.isEmpty || exp - DateTime.now().millisecondsSinceEpoch > _refreshBefore.inMilliseconds) return;
    final r = await Cloud.discordRefresh(refresh);
    if (r.ok) {
      m['access'] = '${r.body['access_token'] ?? ''}';
      m['refresh'] = '${r.body['refresh_token'] ?? ''}';
      m['exp'] = DateTime.now().millisecondsSinceEpoch + (((r.body['expires_in'] as num?)?.toInt() ?? 604800) * 1000);
      if ('${m['access']}'.isNotEmpty && '${m['refresh']}'.isNotEmpty) await _write(pid, m);
    } else if (r.error == 'invalid_token') {
      // Discord no longer knows this link (the person removed PEK TV in their Discord settings): drop it, they can link again.
      await _write(pid, {});
      if (_connectedProfile == pid) await _disconnect();
    }
    // any other error (offline, server busy): keep the old token and try again next time
  }

  // ---------------------------------------------------------------------------------------------- linking

  /// Step 1. Returns the session, or the error code from the cloud (`discord_not_configured`, `rate_limited`, `offline`, ...).
  static Future<(DiscordLinkSession?, String)> startLink() async {
    if (!Cloud.linked) return (null, 'not_linked'); // Discord can only be linked from a signed-in PEK account
    final r = await Cloud.discordStart();
    if (!r.ok) return (null, r.error.isEmpty ? 'server' : r.error);
    final url = '${r.body['url'] ?? ''}';
    final poll = '${r.body['poll'] ?? ''}';
    if (!url.startsWith('https://') || poll.isEmpty) return (null, 'server');
    final life = ((r.body['expiresIn'] as num?)?.toInt() ?? 600).clamp(60, 3600).toInt();
    final every = ((r.body['interval'] as num?)?.toInt() ?? 3).clamp(2, 10).toInt();
    return (
      DiscordLinkSession(url: url, poll: poll, profile: Store.profileId, expiresAt: DateTime.now().millisecondsSinceEpoch + life * 1000, interval: every),
      '',
    );
  }

  /// Step 2, every few seconds: `pending`, `done` (linked, tokens kept), `expired` (start again), `signed_out` (the PEK session is
  /// gone: stop, the person has to sign in again) or `error` (try again next time).
  static Future<String> pollLink(DiscordLinkSession s) async {
    final r = await Cloud.discordPoll(s.poll);
    if (!r.ok) {
      // Cloud._failure turns every 410 into `account_deleted`, so the worker's own word is read from the body.
      if (r.status == 410 || r.body['error'] == 'expired') return 'expired';
      if (r.error == 'not_linked' || r.error == 'session_expired' || r.error == 'account_deleted') return 'signed_out';
      return r.error == 'offline' || r.error == 'rate_limited' ? 'pending' : 'error';
    }
    if (r.body['status'] != 'approved') return 'pending';
    final access = '${r.body['access_token'] ?? ''}';
    final refresh = '${r.body['refresh_token'] ?? ''}';
    final app = '${r.body['appId'] ?? ''}';
    if (access.isEmpty || refresh.isEmpty || app.isEmpty) return 'error';
    await _write(s.profile, {
      'access': access,
      'refresh': refresh,
      'app': app,
      'exp': DateTime.now().millisecondsSinceEpoch + (((r.body['expires_in'] as num?)?.toInt() ?? 604800) * 1000),
      'on': true,
      'titles': true,
    });
    unawaited(_sync());
    return 'done';
  }

  /// Forgets the link for this profile and asks Discord to drop it too.
  static Future<void> unlink() async {
    final pid = Store.profileId;
    final access = '${_read(pid)['access'] ?? ''}';
    await _write(pid, {});
    await _disconnect();
    if (access.isNotEmpty) unawaited(Cloud.discordRevoke(access));
  }

  // ---------------------------------------------------------------------------------------------- what is playing

  static String _lastSent = '';

  /// [type] is play, resume, pause or stop (the same events plugins get). Only movies and episodes arrive here.
  static void playback(String type, {required String kind, required String title, required int year, required int season, required int episode, required double position, required double duration}) {
    if (!showing) return;
    unawaited(_playback(type, kind, title, year, season, episode, position, duration));
  }

  static String _episode(int season, int episode) => season > 0 && episode > 0 ? 'S$season \u00b7 E$episode' : '';

  static Future<void> _playback(String type, String kind, String title, int year, int season, int episode, double position, double duration) async {
    try {
      if (!await available()) return;
      await _sync();
      if (_connectedProfile != Store.profileId) return;
      if (type == 'stop') {
        _lastSent = '';
        await _ch.invokeMethod<void>('clear');
        return;
      }
      final paused = type == 'pause';
      final titles = showTitles;
      final details = titles ? title : 'PEK TV';
      var state = !titles ? 'Watching' : (kind == 'episode' ? _episode(season, episode) : (year > 0 ? '$year' : ''));
      if (paused) state = state.isEmpty ? 'Paused' : '$state \u00b7 Paused';
      final now = DateTime.now().millisecondsSinceEpoch;
      final start = paused ? 0 : now - (position * 1000).round();
      final end = paused || duration <= 0 ? 0 : start + (duration * 1000).round();
      // Discord rate-limits presence: an identical update (same words, the clock within a few seconds) is not sent again.
      final key = '$details|$state|${start ~/ 5000}|${end ~/ 5000}';
      if (key == _lastSent) return;
      _lastSent = key;
      await _ch.invokeMethod<void>('update', {'details': details, 'state': state, 'startMs': start, 'endMs': end});
    } catch (_) {
      // never in the way of the player
    }
  }
}
