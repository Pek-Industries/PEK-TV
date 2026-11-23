import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:http/http.dart' as http;

import 'store.dart';

/// Where the library lives: this device (the C++ server the app runs inside itself, the default) or a self-hosted PEK Server
/// on the home network (selfhost/, SELFHOST.md).
///
/// Only the LIBRARY moves: movies, shows, music, artwork, streams, sources, Fix match, subtitles (see [Api.urlFor]). Plugins, skins,
/// torrents and trailers stay on this device, because the Python plugin host belongs to the app and not to the server.
///
/// Pairing (backend/selfhost.h): the Connect screen finds a server (UDP broadcast, or a typed address), checks it with
/// GET /api/server/info, then trades a 6-digit code from the server for its access key (POST /api/pair). The key is kept here
/// and sent as X-Pek-Token on every library request (or ?pek_t= for libmpv), exactly like the per-launch token of the local server.
class ServerTarget {
  static const _k = 'pek_server_v1';
  static const discoveryPort = 8768; // backend/selfhost_beacon.h (8767 is the phone remote's probe)

  static String _address = ''; // 'http://192.168.1.20:8080', no trailing slash; '' = this device
  static String _key = '';
  static String _name = '';
  static String _id = '';
  static bool _accounts = false; // the server has username + password accounts (backend/accounts.h): sign-in and sync go there

  /// Bumped when the target changes: main.dart rebuilds the app shell, the library pages read their lists again.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// false: the last check could not reach the server (shown in Settings > Library; the app then shows the saved lists).
  static final ValueNotifier<bool> reachable = ValueNotifier<bool>(true);

  /// Set when the server answered 401: its key was changed (pek-server --new-key) and this device must pair again.
  static final ValueNotifier<bool> needsPairing = ValueNotifier<bool>(false);

  static bool get remote => _address.isNotEmpty && _key.isNotEmpty;
  static String get address => _address;
  static String get key => _key;
  static String get name => _name.isNotEmpty ? _name : Uri.tryParse(_address)?.host ?? _address;
  static String get id => _id;
  static bool get accounts => _accounts;

  /// Names for files kept on the device (the last library lists, saved synopses), so two libraries never mix.
  static String savedName(String file) {
    if (!remote) return file;
    final tag = (_id.isNotEmpty ? _id : _address).replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return 'srv_${tag}_$file';
  }

  static void load() {
    final m = Store.jsonMap(_k, scoped: false);
    _address = '${m['address'] ?? ''}';
    _key = '${m['key'] ?? ''}';
    _name = '${m['name'] ?? ''}';
    _id = '${m['id'] ?? ''}';
    _accounts = m['accounts'] == true;
  }

  static Future<void> _save() => Store.setJsonMap(_k, {'address': _address, 'key': _key, 'name': _name, 'id': _id, 'accounts': _accounts}, scoped: false);

  /// Use [s] from now on (after a successful pairing).
  static Future<void> use(FoundServer s, String key) async {
    _address = s.address;
    _key = key;
    _name = s.name;
    _id = s.id;
    _accounts = s.accounts;
    reachable.value = true;
    needsPairing.value = false;
    await _save();
    changes.value++;
  }

  /// Back to the library on this device. The server keeps its key; pairing again later needs a new code.
  static Future<void> useThisDevice() async {
    _address = _key = _name = _id = '';
    _accounts = false;
    reachable.value = true;
    needsPairing.value = false;
    await _save();
    changes.value++;
  }

  // ---------------------------------------------------------------- addresses

  /// What people type: "192.168.1.20", "192.168.1.20:8080", "nas.local", "http://..." or "https://pek.example.com" (a reverse
  /// proxy). No scheme = http; no scheme and no port = port 8080. Returns '' when it cannot be an address.
  static String normalize(String typed) {
    var t = typed.trim();
    if (t.isEmpty) return '';
    final hasScheme = t.startsWith('http://') || t.startsWith('https://');
    if (!hasScheme) t = 'http://$t';
    final u = Uri.tryParse(t);
    if (u == null || u.host.isEmpty) return '';
    final port = u.hasPort ? u.port : (hasScheme ? null : 8080);
    final b = StringBuffer('${u.scheme}://${u.host.contains(':') ? '[${u.host}]' : u.host}');
    if (port != null) b.write(':$port');
    final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path; // a reverse proxy under /pek
    b.write(path);
    return b.toString();
  }

  /// Plain HTTP over the internet sends the key in the clear. True for a public address without https.
  static bool insecure(String address) {
    final u = Uri.tryParse(address);
    if (u == null || u.scheme == 'https') return false;
    final h = u.host;
    if (h == 'localhost' || h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.home.arpa') || h.endsWith('.ts.net')) return false;
    final ip = InternetAddress.tryParse(h);
    if (ip == null) return true; // a domain name without https: probably on the internet
    if (ip.isLoopback || ip.isLinkLocal) return false;
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      if (b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168)) return false;
      if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return false; // Tailscale / CGNAT
      return true;
    }
    return (b[0] & 0xfe) != 0xfc; // IPv6: only fc00::/7 counts as private
  }

  // ---------------------------------------------------------------- talking to a server (no key needed for these)

  static final http.Client _http = http.Client();

  /// GET /api/server/info. Throws [ServerError] with a sentence for the person when it is not a PEK Server.
  static Future<FoundServer> probe(String address) async {
    http.Response r;
    try {
      r = await _http.get(Uri.parse('$address/api/server/info')).timeout(const Duration(seconds: 6));
    } on TimeoutException {
      throw const ServerError('No answer from that address. Is the server running, and is this device on the same network?');
    } catch (_) {
      throw const ServerError('Could not reach that address. Check it, and that the server is running.');
    }
    if (r.statusCode == 404 || r.statusCode == 401) {
      throw const ServerError('Something answered, but it is not a PEK Server that can pair (an older version needs updating).');
    }
    if (r.statusCode != 200) throw ServerError('The server answered HTTP ${r.statusCode}.');
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      if (j['app'] != 'pek-server') throw const FormatException();
      return FoundServer.fromJson(Map<String, dynamic>.from(j), address);
    } catch (_) {
      throw const ServerError('That address is not a PEK Server.');
    }
  }

  /// Trades the 6-digit code shown by the server for its access key (POST /api/pair).
  static Future<String> pair(String address, String code) async {
    http.Response r;
    try {
      r = await _http.post(Uri.parse('$address/api/pair'), body: {'code': code}).timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const ServerError('Could not reach the server. Try again.');
    }
    Map<String, dynamic> j = const {};
    try {
      j = Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
    } catch (_) {}
    if (r.statusCode == 200 && j['ok'] == true && '${j['key'] ?? ''}'.isNotEmpty) return '${j['key']}';
    throw ServerError('${j['error'] ?? 'Pairing failed (HTTP ${r.statusCode}).'}');
  }

  /// Checks a typed access key (from pairing.txt) by asking for something only a paired device may see.
  static Future<void> checkKey(String address, String key) async {
    http.Response r;
    try {
      r = await _http.get(Uri.parse('$address/api/scan-status'), headers: {'X-Pek-Token': key}).timeout(const Duration(seconds: 8));
    } catch (_) {
      throw const ServerError('Could not reach the server. Try again.');
    }
    if (r.statusCode == 401) throw const ServerError('The server did not accept that key.');
    if (r.statusCode != 200) throw ServerError('The server answered HTTP ${r.statusCode}.');
  }

  /// A paired device asks for a new code for the next device ("Pair another device").
  static Future<String> newCode() async {
    final r = await _http.post(Uri.parse('$_address/api/pair/new'), headers: {'X-Pek-Token': _key}).timeout(const Duration(seconds: 8));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode != 200 || j is! Map || '${j['code'] ?? ''}'.length != 6) throw ServerError('The server answered HTTP ${r.statusCode}.');
    return '${j['code']}';
  }

  /// Is the chosen server there and does it still take our key? Updates [reachable] / [needsPairing]. Called at start-up.
  static Future<bool> check() async {
    if (!remote) return true;
    try {
      final r = await _http.get(Uri.parse('$_address/api/scan-status'), headers: {'X-Pek-Token': _key}).timeout(const Duration(seconds: 6));
      needsPairing.value = r.statusCode == 401;
      reachable.value = r.statusCode == 200 || r.statusCode == 401;
      if (r.statusCode == 200) unawaited(_refreshInfo());
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[server] $_address not reachable: $e');
      reachable.value = false;
      // The address may have changed (DHCP): look for the same server id on the network and follow it.
      if (_id.isNotEmpty) {
        for (final s in await discover(wait: const Duration(milliseconds: 1500))) {
          if (s.id == _id && s.address != _address) {
            debugPrint('[server] found it again at ${s.address}');
            _address = s.address;
            await _save();
            changes.value++;
            return check();
          }
        }
      }
      return false;
    }
  }

  /// The owner made the first account (or removed the last one) since this device paired: follow it. Only an answer changes it,
  /// so a server that is away never signs anybody out.
  static Future<void> _refreshInfo() async {
    try {
      final s = await probe(_address);
      if (s.accounts != _accounts || (s.name.isNotEmpty && s.name != _name)) {
        _accounts = s.accounts;
        _name = s.name;
        await _save();
        changes.value++;
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------- finding servers on the network

  /// Shouts "PEK_DISCOVER 1" on UDP [discoveryPort] and collects the answers for [wait]. Servers in Docker's bridge network or on
  /// another subnet do not hear it; those are typed in.
  static Future<List<FoundServer>> discover({Duration wait = const Duration(milliseconds: 2500)}) async {
    final found = <String, FoundServer>{};
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final s = sock;
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null) return;
        try {
          final j = Map<String, dynamic>.from(jsonDecode(utf8.decode(d.data)) as Map);
          if (j['app'] != 'pek-server') return;
          final port = (j['port'] as num?)?.toInt() ?? 8080;
          final f = FoundServer.fromJson(j, 'http://${d.address.address}:$port');
          found[f.id.isNotEmpty ? f.id : f.address] = f;
        } catch (_) {}
      });
      // The plain broadcast, plus each network's own broadcast address (some routers / Android versions drop 255.255.255.255).
      final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
      try {
        for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
          for (final a in nic.addresses) {
            final b = a.rawAddress;
            if (a.isLoopback || b[0] == 169) continue;
            targets.add(InternetAddress.fromRawAddress(Uint8List.fromList([b[0], b[1], b[2], 255]))); // assumes a /24 home network
          }
        }
      } catch (_) {}
      final msg = utf8.encode('PEK_DISCOVER 1');
      // Sent three times (UDP can be dropped), answers are collected the whole time.
      for (var round = 0; round < 3; round++) {
        for (final t in targets) {
          try {
            s.send(msg, t, discoveryPort);
          } catch (_) {}
        }
        await Future<void>.delayed(Duration(milliseconds: wait.inMilliseconds ~/ 3));
      }
    } catch (e) {
      debugPrint('[server] discovery failed: $e');
    } finally {
      sock?.close();
    }
    final list = found.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }
}

/// A PEK Server that answered (discovery or GET /api/server/info).
class FoundServer {
  const FoundServer({required this.address, required this.name, required this.id, required this.version, required this.pairing, this.accounts = false, this.update = '', this.platform = ''});
  final String address;
  final String name;
  final String id;
  final String version;
  final bool pairing; // a code is open on it right now
  final bool accounts; // people can sign in with a username and password (and then do not need a pairing code)
  final String update; // a newer PEK Server version the server found, or '' (servers only check; they never update by themselves)
  final String platform; // windows | linux | termux | docker: how the owner updates it

  factory FoundServer.fromJson(Map<String, dynamic> j, String address) => FoundServer(
        address: address,
        name: '${j['name'] ?? ''}'.isNotEmpty ? '${j['name']}' : (Uri.tryParse(address)?.host ?? address),
        id: '${j['id'] ?? ''}',
        version: '${j['version'] ?? ''}',
        pairing: j['pairing'] == true,
        accounts: j['accounts'] == true,
        update: '${j['update'] ?? ''}',
        platform: '${j['platform'] ?? ''}',
      );
}

class ServerError implements Exception {
  const ServerError(this.message);
  final String message;
  @override
  String toString() => message;
}
