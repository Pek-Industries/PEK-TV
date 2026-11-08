import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_pairing.dart';

/// A TV the phone has paired with before (the token is what lets it back in without a code).
class SavedTv {
  SavedTv({required this.id, required this.name, required this.host, required this.port, required this.token});
  final String id;
  String name;
  String host;
  int port;
  final String token;

  Map<String, Object> toJson() => {'id': id, 'name': name, 'host': host, 'port': port, 'token': token};
}

/// A TV that answered the search.
class FoundTv {
  const FoundTv({required this.id, required this.name, required this.host, required this.port});
  final String id;
  final String name;
  final String host;
  final int port;
}

enum RemoteState { idle, connecting, needPair, ready, lost }

/// What the TV says about the text box that has the focus.
class RemoteField {
  const RemoteField({this.on = false, this.fid = 0, this.text = '', this.hide = false, this.multi = false});
  final bool on;
  final int fid; // changes when another box gets the focus
  final String text;
  final bool hide;
  final bool multi;
}

/// The phone side: finds a TV, pairs, and sends keys / text / media commands (see remote_host.dart for the other end).
class RemoteClient extends ChangeNotifier {
  RemoteClient._();
  static final RemoteClient instance = RemoteClient._();

  RemoteState state = RemoteState.idle;
  String error = '';
  String tvName = '';
  RemoteField field = const RemoteField();
  bool playing = false;
  int pos = 0;
  int dur = 0;
  List<SavedTv> saved = [];
  List<FoundTv> found = [];
  bool searching = false;

  WebSocket? _ws;
  String _deviceId = '';
  String _host = '';
  int _port = RemoteProtocol.wsPort;
  String _tvId = '';
  Timer? _retry;
  bool _wantConnected = false;
  int _retries = 0;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString('remote.deviceId') ?? _newId(prefs);
    saved = [];
    try {
      final l = jsonDecode(prefs.getString('remote.tvs') ?? '[]');
      if (l is List) {
        for (final e in l) {
          if (e is Map) {
            saved.add(SavedTv(id: '${e['id']}', name: '${e['name']}', host: '${e['host']}', port: (e['port'] as num?)?.toInt() ?? RemoteProtocol.wsPort, token: '${e['token']}'));
          }
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  String _newId(SharedPreferences prefs) {
    final r = Random.secure();
    final id = [for (var i = 0; i < 12; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    prefs.setString('remote.deviceId', id);
    return id;
  }

  Future<void> _saveTvs() async => (await SharedPreferences.getInstance()).setString('remote.tvs', jsonEncode([for (final t in saved) t.toJson()]));

  Future<void> forget(SavedTv t) async {
    saved.remove(t);
    await _saveTvs();
    notifyListeners();
  }

  // ------------------------------------------------------------------------------------------------ finding TVs

  /// Shouts the probe to the whole network and collects the answers for a couple of seconds.
  Future<void> search({Duration wait = const Duration(milliseconds: 2500)}) async {
    if (searching) return;
    searching = true;
    found = [];
    notifyListeners();
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final seen = <String, FoundTv>{};
      sock.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = sock!.receive();
        if (d == null) return;
        try {
          final m = jsonDecode(utf8.decode(d.data, allowMalformed: true));
          if (m is Map && m['app'] == 'pek' && m['id'] is String) {
            seen['${m['id']}'] = FoundTv(id: '${m['id']}', name: '${m['name'] ?? 'PEK TV'}', host: d.address.address, port: (m['port'] as num?)?.toInt() ?? RemoteProtocol.wsPort);
            found = seen.values.toList();
            notifyListeners();
          }
        } catch (_) {}
      });
      final data = utf8.encode(RemoteProtocol.probe);
      final targets = <String>{'255.255.255.255'};
      try {
        for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
          for (final a in i.addresses) {
            final p = a.address.split('.');
            if (!a.isLoopback && p.length == 4) targets.add('${p[0]}.${p[1]}.${p[2]}.255'); // the usual /24
          }
        }
      } catch (_) {}
      for (var round = 0; round < 3; round++) {
        for (final t in targets) {
          try {
            sock.send(data, InternetAddress(t), RemoteProtocol.discoveryPort);
          } catch (_) {}
        }
        await Future<void>.delayed(wait ~/ 3);
      }
    } catch (_) {
      // no Wi-Fi: the list stays empty and the person can type an address
    } finally {
      sock?.close();
      searching = false;
      // A saved TV may have a new address (the router handed out another one): keep it up to date.
      var changed = false;
      for (final f in found) {
        for (final s in saved) {
          if (s.id == f.id && (s.host != f.host || s.port != f.port || s.name != f.name)) {
            s.host = f.host;
            s.port = f.port;
            s.name = f.name;
            changed = true;
          }
        }
      }
      if (changed) unawaited(_saveTvs());
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------------------------------------ connecting

  /// Opens the Remote screen: reconnects to the last TV used (looking for its new address first), or does nothing if none.
  Future<void> autoConnect() async {
    if (state == RemoteState.ready || state == RemoteState.connecting || state == RemoteState.needPair) return;
    if (_deviceId.isEmpty) await load();
    if (saved.isEmpty) {
      unawaited(search());
      return;
    }
    final last = saved.first;
    await connect(last.host, last.port, tvId: last.id);
  }

  Future<void> connect(String host, int port, {String tvId = ''}) async {
    await _close();
    _wantConnected = true;
    _host = host;
    _port = port;
    _tvId = tvId;
    error = '';
    state = RemoteState.connecting;
    field = const RemoteField();
    notifyListeners();
    try {
      final ws = await WebSocket.connect('ws://$host:$port/ws').timeout(const Duration(seconds: 4));
      ws.pingInterval = const Duration(seconds: 10);
      _ws = ws;
      ws.listen(_onData, onDone: () => _dropped(ws), onError: (Object _) => _dropped(ws), cancelOnError: true);
      SavedTv? mine;
      for (final s in saved) {
        if ((tvId.isNotEmpty && s.id == tvId) || (tvId.isEmpty && s.host == host && s.port == port)) mine = s;
      }
      _send({'t': 'hello', 'id': _deviceId, 'name': 'Android phone', 'token': mine?.token ?? ''});
    } catch (_) {
      _failed("Couldn't reach the TV. Is PEK TV open on it, and is the phone on the same Wi-Fi?");
    }
  }

  void _failed(String msg) {
    state = RemoteState.lost;
    error = msg;
    notifyListeners();
    _scheduleRetry();
  }

  void _dropped(WebSocket ws) {
    if (!identical(ws, _ws)) return;
    _ws = null;
    if (state == RemoteState.ready) {
      state = RemoteState.lost;
      error = 'Lost the connection to the TV.';
      notifyListeners();
      _scheduleRetry();
    } else if (state == RemoteState.connecting || state == RemoteState.needPair) {
      state = RemoteState.lost;
      notifyListeners();
    }
  }

  /// After a drop: try again a few times (the TV may have been asleep or got a new address), then wait for a tap.
  void _scheduleRetry() {
    _retry?.cancel();
    if (!_wantConnected || _retries >= 4) return;
    _retries++;
    _retry = Timer(Duration(seconds: 2 * _retries), () async {
      if (!_wantConnected || state == RemoteState.ready) return;
      if (_tvId.isNotEmpty) {
        await search(wait: const Duration(milliseconds: 1500));
        for (final f in found) {
          if (f.id == _tvId) {
            _host = f.host;
            _port = f.port;
          }
        }
      }
      await connect(_host, _port, tvId: _tvId);
    });
  }

  Future<void> retryNow() async {
    _retries = 0;
    await connect(_host, _port, tvId: _tvId);
  }

  Future<void> pair(String pin) async {
    error = '';
    _send({'t': 'pair', 'id': _deviceId, 'name': 'Android phone', 'pin': pin.trim()});
    notifyListeners();
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> m;
    try {
      final j = jsonDecode(data);
      if (j is! Map<String, dynamic>) return;
      m = j;
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'ready':
        _retries = 0;
        tvName = '${m['name'] ?? 'PEK TV'}';
        if ('${m['id'] ?? ''}'.isNotEmpty) _tvId = '${m['id']}';
        state = RemoteState.ready;
      case 'need_pair':
        tvName = '${m['name'] ?? 'PEK TV'}';
        if ('${m['id'] ?? ''}'.isNotEmpty) _tvId = '${m['id']}';
        state = RemoteState.needPair;
      case 'paired':
        _retries = 0;
        tvName = '${m['name'] ?? 'PEK TV'}';
        _tvId = '${m['id'] ?? ''}';
        saved.removeWhere((s) => s.id == _tvId);
        saved.insert(0, SavedTv(id: _tvId, name: tvName, host: _host, port: _port, token: '${m['token']}'));
        unawaited(_saveTvs());
        state = RemoteState.ready;
        error = '';
      case 'error':
        error = m['e'] == 'closed' ? 'Pairing is not open. On the TV, open Remote and tap Pair a phone.' : 'That code is not right.';
      case 'field':
        field = RemoteField(on: m['on'] == true, fid: (m['fid'] as num?)?.toInt() ?? 0, text: '${m['text'] ?? ''}', hide: m['hide'] == true, multi: m['multi'] == true);
      case 'status':
        playing = m['playing'] == true;
        pos = (m['pos'] as num?)?.toInt() ?? 0;
        dur = (m['dur'] as num?)?.toInt() ?? 0;
    }
    notifyListeners();
  }

  void _send(Map<String, Object?> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  Future<void> _close() async {
    _retry?.cancel();
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } catch (_) {}
  }

  /// The person left the Remote screen or picked "Change TV".
  Future<void> disconnect() async {
    _wantConnected = false;
    await _close();
    state = RemoteState.idle;
    error = '';
    notifyListeners();
  }

  // ------------------------------------------------------------------------------------------------ commands

  void key(String k) => _send({'t': 'key', 'k': k});
  void nav(String a) => _send({'t': 'nav', 'a': a});
  void text(String v) => _send({'t': 'text', 'v': v});
  void submit() => _send({'t': 'submit'});
  void playPause() => _send({'t': 'media', 'a': 'playpause'});
  void seek(double sec) => _send({'t': 'media', 'a': 'seek', 'd': sec});
  void volume(int dir) => _send({'t': 'media', 'a': 'volume', 'd': dir});
}
