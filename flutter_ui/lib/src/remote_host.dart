import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'deep_link.dart';
import 'mpv.dart';
import 'remote_pairing.dart';

/// The TV side of "use your phone as a remote and keyboard".
///
/// A small listener of its own (the C++ server stays on 127.0.0.1 and is not touched). It speaks WebSocket on port 8766 and answers
/// a UDP probe on 8767 so a phone can find the TV. A phone must pair first (remote_pairing.dart); after that it can only send
/// arrow / OK / Menu keys, Back, Home, text for the focused text box, and play / pause / seek / volume. Nothing else.
///
/// Keys are fed into Flutter's own key pipeline, so the focus system, KeyGuard and TV navigation treat them exactly like a real remote.
class RemoteHost extends ChangeNotifier {
  RemoteHost._();
  static final RemoteHost instance = RemoteHost._();

  static const _hostChannel = MethodChannel('pek/host');

  final RemotePairing pairing = RemotePairing();
  HttpServer? _http;
  RawDatagramSocket? _udp;
  Timer? _tick;
  final List<_Session> _sessions = [];
  String _hostId = '';
  String name = 'PEK TV';
  bool enabled = false;
  String error = '';

  bool get running => _http != null;
  int get connected => _sessions.where((s) => s.authed).length;

  /// Called once at start-up. On a TV the listener is on unless the person turned it off; on a phone it is off unless turned on.
  Future<void> startIfWanted({required bool isPhone}) async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool('remote.enabled') ?? !isPhone;
    _hostId = prefs.getString('remote.hostId') ?? _randomId(prefs);
    name = prefs.getString('remote.hostName') ?? 'PEK TV';
    pairing.load(prefs.getString('remote.paired'));
    if (enabled) await start();
    notifyListeners();
  }

  String _randomId(SharedPreferences prefs) {
    final r = Random.secure();
    final id = [for (var i = 0; i < 8; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    prefs.setString('remote.hostId', id);
    return id;
  }

  Future<void> setEnabled(bool on) async {
    enabled = on;
    (await SharedPreferences.getInstance()).setBool('remote.enabled', on);
    if (on) {
      await start();
    } else {
      await stop();
    }
    notifyListeners();
  }

  Future<void> setName(String v) async {
    name = v.trim().isEmpty ? 'PEK TV' : v.trim();
    (await SharedPreferences.getInstance()).setString('remote.hostName', name);
    notifyListeners();
  }

  Future<void> start() async {
    if (running) return;
    error = '';
    try {
      final http = await HttpServer.bind(InternetAddress.anyIPv4, RemoteProtocol.wsPort, shared: true);
      _http = http;
      http.listen(_onRequest, onError: (Object _) {});
    } catch (e) {
      error = 'Could not open port ${RemoteProtocol.wsPort}: $e';
      notifyListeners();
      return;
    }
    try {
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, RemoteProtocol.discoveryPort, reuseAddress: true);
      udp.broadcastEnabled = true;
      udp.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = udp.receive();
        if (d == null || d.data.length > 64) return;
        if (utf8.decode(d.data, allowMalformed: true).trim() != RemoteProtocol.probe) return;
        final reply = jsonEncode({'app': 'pek', 'id': _hostId, 'name': name, 'port': RemoteProtocol.wsPort});
        udp.send(utf8.encode(reply), d.address, d.port);
      });
      _udp = udp;
    } catch (_) {
      // No discovery: a phone can still connect with the address or a saved TV.
    }
    unawaited(PekPlayer.setMulticast(true)); // some Wi-Fi chips drop broadcasts without this
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => _pushState());
    notifyListeners();
  }

  Future<void> stop() async {
    _tick?.cancel();
    _tick = null;
    for (final s in List.of(_sessions)) {
      s.close();
    }
    _sessions.clear();
    _udp?.close();
    _udp = null;
    await _http?.close(force: true);
    _http = null;
    pairing.close();
    notifyListeners();
  }

  /// Opens pairing and returns the code to show on screen.
  String openPairing() {
    final pin = pairing.open();
    notifyListeners();
    return pin;
  }

  void closePairing() {
    pairing.close();
    notifyListeners();
  }

  Future<void> revoke(String id) async {
    pairing.revoke(id);
    for (final s in List.of(_sessions)) {
      if (s.id == id) s.close();
    }
    await _save();
    notifyListeners();
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString('remote.paired', pairing.toJson());

  /// The TV's own address on the Wi-Fi / Ethernet, for the pairing screen ("or type this on the phone").
  static Future<String> localAddress() async {
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.address.startsWith('169.254.')) return a.address;
        }
      }
    } catch (_) {}
    return '';
  }

  // ------------------------------------------------------------------------------------------------ connections

  Future<void> _onRequest(HttpRequest req) async {
    // A web page cannot drive the TV: browsers always send an Origin header, the app never does.
    if (req.headers.value('origin') != null || req.uri.path != '/ws' || !WebSocketTransformer.isUpgradeRequest(req) || _sessions.length >= 6) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    try {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.pingInterval = const Duration(seconds: 10);
      final s = _Session(ws);
      _sessions.add(s);
      // Nothing but "hello" / "pair" is accepted, and only for 20 seconds, until the phone is let in.
      s.authTimer = Timer(const Duration(seconds: 20), () {
        if (!s.authed) s.close();
      });
      ws.listen(
        (data) => _onMessage(s, data),
        onDone: () {
          s.authTimer?.cancel();
          _sessions.remove(s);
          notifyListeners();
        },
        onError: (Object _) => s.close(),
        cancelOnError: true,
      );
    } catch (_) {}
  }

  void _onMessage(_Session s, dynamic data) {
    if (data is! String || data.length > RemoteProtocol.maxMessage) {
      s.close();
      return;
    }
    Map<String, dynamic> m;
    try {
      final j = jsonDecode(data);
      if (j is! Map<String, dynamic>) return;
      m = j;
    } catch (_) {
      return;
    }
    final t = m['t'];
    if (!s.authed) {
      final id = _str(m['id'], 64);
      final phoneName = _str(m['name'], 40);
      if (t == 'hello') {
        if (pairing.checkToken(id, _str(m['token'], 128))) {
          _admit(s, id);
          s.send({'t': 'ready', 'id': _hostId, 'name': name});
        } else {
          s.send({'t': 'need_pair', 'id': _hostId, 'name': name, 'open': pairing.isOpen});
        }
      } else if (t == 'pair') {
        final token = pairing.tryPair(id, phoneName, _str(m['pin'], 12));
        if (token == null) {
          s.send({'t': 'error', 'e': pairing.isOpen ? 'bad_pin' : 'closed'});
        } else {
          _admit(s, id);
          unawaited(_save());
          s.send({'t': 'paired', 'token': token, 'id': _hostId, 'name': name});
        }
        notifyListeners();
      }
      return;
    }
    switch (t) {
      case 'key':
        _pressKey(_str(m['k'], 12));
      case 'nav':
        _nav(_str(m['a'], 12));
      case 'text':
        _setText(_str(m['v'], 1000));
      case 'submit':
        _submit();
      case 'media':
        _media(_str(m['a'], 12), (m['d'] is num) ? (m['d'] as num).toDouble() : 0);
      case 'ping':
        s.send({'t': 'pong'});
    }
  }

  void _admit(_Session s, String id) {
    s.authed = true;
    s.id = id;
    s.authTimer?.cancel();
    s.lastField = '';
    s.lastStatus = '';
    notifyListeners();
  }

  static String _str(dynamic v, int max) => v is String ? (v.length > max ? v.substring(0, max) : v) : '';

  // ------------------------------------------------------------------------------------------------ doing things

  static final Map<String, (PhysicalKeyboardKey, LogicalKeyboardKey)> _keyMap = {
    'up': (PhysicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowUp),
    'down': (PhysicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowDown),
    'left': (PhysicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowLeft),
    'right': (PhysicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowRight),
    'ok': (PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter),
    'menu': (PhysicalKeyboardKey.contextMenu, LogicalKeyboardKey.contextMenu), // the app already reads Menu as press-and-hold
  };

  /// One key press through the same path the engine uses for a real keyboard / remote.
  void _pressKey(String k) {
    final pair = _keyMap[k];
    if (pair == null) return;
    final d = ui.PlatformDispatcher.instance;
    ui.KeyData data(ui.KeyEventType type) => ui.KeyData(
          timeStamp: Duration(microseconds: DateTime.now().microsecondsSinceEpoch),
          type: type,
          physical: pair.$1.usbHidUsage,
          logical: pair.$2.keyId,
          character: null,
          synthesized: false,
        );
    d.onKeyData?.call(data(ui.KeyEventType.down));
    Timer(const Duration(milliseconds: 40), () => d.onKeyData?.call(data(ui.KeyEventType.up)));
  }

  void _nav(String a) {
    final nav = DeepLink.navKey.currentState;
    if (nav == null) return;
    if (a == 'back') {
      nav.maybePop();
    } else if (a == 'home') {
      nav.popUntil((r) => r.isFirst);
    }
  }

  EditableTextState? _field() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return null;
    return ctx.findAncestorStateOfType<EditableTextState>();
  }

  void _setText(String v) {
    final f = _field();
    if (f == null) return;
    f.userUpdateTextEditingValue(TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length)), SelectionChangedCause.keyboard);
  }

  void _submit() {
    final f = _field();
    if (f == null) return;
    f.performAction(f.widget.textInputAction ?? TextInputAction.done);
  }

  void _media(String a, double d) {
    final p = PekPlayer.shared;
    switch (a) {
      case 'playpause':
        unawaited(p.togglePause());
      case 'seek':
        final dur = p.duration.value;
        var to = p.position.value + d.clamp(-600, 600);
        if (to < 0) to = 0;
        if (dur > 0 && to > dur) to = dur;
        unawaited(p.seek(to));
      case 'volume':
        // +1 louder, -1 quieter, 0 mute: the Android side moves the system music volume and shows its own bar.
        _hostChannel.invokeMethod<void>('volume', {'dir': d.sign.toInt()}).catchError((Object _) {});
    }
  }

  // ------------------------------------------------------------------------------------------------ what the phone sees

  void _pushState() {
    final live = _sessions.where((s) => s.authed).toList();
    if (live.isEmpty) return;

    final f = _field();
    final field = f == null
        ? {'t': 'field', 'on': false}
        : {'t': 'field', 'on': true, 'fid': identityHashCode(f), 'text': f.textEditingValue.text, 'hide': f.widget.obscureText, 'multi': (f.widget.maxLines ?? 1) != 1};
    final fieldJson = jsonEncode(field);

    final p = PekPlayer.shared;
    final dur = p.duration.value;
    final status = {'t': 'status', 'playing': p.playing.value, 'pos': p.position.value.floor(), 'dur': dur.floor()};
    final statusJson = jsonEncode(status);

    for (final s in live) {
      if (s.lastField != fieldJson) {
        s.lastField = fieldJson;
        s.sendRaw(fieldJson);
      }
      if (s.lastStatus != statusJson) {
        s.lastStatus = statusJson;
        s.sendRaw(statusJson);
      }
    }
  }
}

class _Session {
  _Session(this.ws);
  final WebSocket ws;
  bool authed = false;
  String id = '';
  Timer? authTimer;
  String lastField = '';
  String lastStatus = '';

  void send(Map<String, Object?> m) => sendRaw(jsonEncode(m));
  void sendRaw(String s) {
    try {
      ws.add(s);
    } catch (_) {}
  }

  void close() {
    authTimer?.cancel();
    try {
      ws.close();
    } catch (_) {}
  }
}
