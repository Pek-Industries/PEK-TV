import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Ports and words shared by the TV side (remote_host.dart) and the phone side (remote_client.dart).
class RemoteProtocol {
  static const wsPort = 8766; // the TV listens here (WebSocket on /ws)
  static const discoveryPort = 8767; // UDP: the phone shouts the probe, the TV answers it
  static const probe = 'PEKREMOTE1?';
  static const maxMessage = 4096; // bytes; a bigger message closes the connection
  static const keys = {'up', 'down', 'left', 'right', 'ok', 'menu'};
  static const navs = {'back', 'home'};
}

class PairedDevice {
  const PairedDevice({required this.id, required this.name, required this.hash});
  final String id;
  final String name;
  final String hash; // SHA-256 of the token; the token itself is only ever kept by the phone

  Map<String, String> toJson() => {'id': id, 'name': name, 'hash': hash};
}

/// Who may drive the TV. A phone has to pair once with a 6-digit code that the TV shows only while its "Pair a phone" screen is
/// open; it is then given a long random token. The TV keeps only the token's hash. Pure Dart, so it is easy to test.
///
///  - The code lasts 5 minutes, works once, and 5 wrong guesses close pairing (the TV has to open it again, with a new code).
///  - Tokens are compared in constant time.
///  - At most [maxDevices] phones; the oldest is dropped to make room.
class RemotePairing {
  RemotePairing({Random? random, DateTime Function()? now})
      : _rng = random ?? Random.secure(),
        _now = now ?? DateTime.now;

  static const maxDevices = 8;
  static const maxGuesses = 5;
  static const pinLife = Duration(minutes: 5);

  final Random _rng;
  final DateTime Function() _now;
  final Map<String, PairedDevice> _devices = {};
  String? _pin;
  DateTime _pinEnds = DateTime.fromMillisecondsSinceEpoch(0);
  int _guesses = 0;

  List<PairedDevice> get devices => List.unmodifiable(_devices.values);

  bool get isOpen => _pin != null && _now().isBefore(_pinEnds);
  String? get pin => isOpen ? _pin : null;
  Duration get timeLeft => isOpen ? _pinEnds.difference(_now()) : Duration.zero;

  /// Starts pairing: a fresh 6-digit code.
  String open() {
    _pin = _rng.nextInt(1000000).toString().padLeft(6, '0');
    _pinEnds = _now().add(pinLife);
    _guesses = 0;
    return _pin!;
  }

  void close() {
    _pin = null;
    _guesses = 0;
  }

  /// The token for a phone that gave the right code, or null. A wrong guess counts against the five.
  String? tryPair(String id, String name, String pin) {
    if (!isOpen || id.isEmpty) return null;
    if (!_same(pin, _pin!)) {
      if (++_guesses >= maxGuesses) close();
      return null;
    }
    close(); // one code, one phone
    final token = _newToken();
    _devices.remove(id);
    _devices[id] = PairedDevice(id: id, name: name.isEmpty ? 'Phone' : name, hash: _hash(token));
    while (_devices.length > maxDevices) {
      _devices.remove(_devices.keys.first);
    }
    return token;
  }

  bool checkToken(String id, String token) {
    final d = _devices[id];
    if (d == null || token.isEmpty) return false;
    return _same(_hash(token), d.hash);
  }

  void revoke(String id) => _devices.remove(id);
  void revokeAll() => _devices.clear();

  String toJson() => jsonEncode([for (final d in _devices.values) d.toJson()]);

  void load(String? json) {
    _devices.clear();
    if (json == null || json.isEmpty) return;
    try {
      final l = jsonDecode(json);
      if (l is! List) return;
      for (final e in l) {
        if (e is Map && e['id'] is String && e['hash'] is String) {
          _devices['${e['id']}'] = PairedDevice(id: '${e['id']}', name: '${e['name'] ?? 'Phone'}', hash: '${e['hash']}');
        }
      }
    } catch (_) {}
  }

  String _newToken() => [for (var i = 0; i < 32; i++) _rng.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  static String _hash(String token) => sha256.convert(utf8.encode(token)).toString();

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
