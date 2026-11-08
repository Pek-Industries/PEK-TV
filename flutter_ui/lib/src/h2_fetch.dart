import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/http2.dart';

/// One answer: the HTTP status and the whole body.
typedef H2Reply = ({int status, Uint8List bytes});

/// Thrown when HTTP/2 cannot be used for this request at all (the server does not offer it, the connection could not be made, or
/// it was switched off after repeated failures). The caller then uses the ordinary HTTP/1.1 download instead.
class H2Unavailable implements Exception {
  const H2Unavailable(this.why);
  final String why;
  @override
  String toString() => 'H2Unavailable: $why';
}

/// Downloads over HTTP/2 (the pure-Dart `http2` package), for the pictures. dart:io's HttpClient only speaks HTTP/1.1: one request
/// per connection, so a screen of 20 posters meant 20 TCP + TLS handshakes, and a connection that had died silently held a poster
/// until its timeout. Here ONE connection per host carries every request at the same time (streams), so the handshake is paid once.
///
///  * the connection is kept; a new one is made when it closed, got a GOAWAY, or does not answer a ping after sitting idle
///  * a request that gets no answer within its time is cancelled alone (RST_STREAM); the connection is then pinged, and only a
///    connection that does not answer that is thrown away (so one slow picture does not break the 19 others on it)
///  * a body shorter than the announced content-length counts as failed, so half a picture is never saved
///  * 3 failed connection attempts in a row (or a server that answers "http/1.1" in ALPN) switch HTTP/2 off for the rest of the
///    run: [get] then throws [H2Unavailable] and everything goes the old way
class H2Fetch {
  H2Fetch._();

  static final Map<String, Future<_H2Conn?>> _conns = {};
  static int _failures = 0;
  static const _maxFailures = 3;

  static bool get broken => _failures >= _maxFailures;

  /// Makes the connection to [uri]'s host now (DNS + TCP + TLS), so the first pictures do not wait for it. false = no HTTP/2 here.
  static Future<bool> warm(Uri uri, Duration timeout) async {
    if (broken || uri.scheme != 'https') return false;
    try {
      await _conn(uri.host, uri.hasPort ? uri.port : 443, timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// null = it failed or timed out (the caller may ask again); throws [H2Unavailable] when HTTP/2 cannot be used at all.
  static Future<H2Reply?> get(Uri uri, Duration timeout) async {
    if (broken || uri.scheme != 'https') throw const H2Unavailable('not available');
    final sw = Stopwatch()..start();
    final c = await _conn(uri.host, uri.hasPort ? uri.port : 443, timeout);
    final left = timeout - sw.elapsed;
    if (left < const Duration(milliseconds: 300)) return null;
    return c.get(uri, left);
  }

  static Future<_H2Conn> _conn(String host, int port, Duration timeout) async {
    final key = '$host:$port';
    for (var i = 0; i < 2; i++) {
      final f = _conns[key];
      if (f == null) break;
      final c = await f;
      if (c != null && c.usable && await c.alive()) return c;
      if (identical(_conns[key], f)) _conns.remove(key); // closed, failed or not answering: a new one is made below
    }
    var f = _conns[key];
    if (f == null) {
      f = _connect(host, port, timeout);
      _conns[key] = f;
    }
    final c = await f;
    if (c == null || !c.usable) {
      if (identical(_conns[key], f)) _conns.remove(key);
      throw const H2Unavailable('no connection');
    }
    return c;
  }

  static Future<_H2Conn?> _connect(String host, int port, Duration timeout) async {
    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(host, port, supportedProtocols: const ['h2'], timeout: timeout);
      if (socket.selectedProtocol != 'h2') {
        _failures = _maxFailures; // this server does not do HTTP/2: HTTP/1.1 for the rest of the run
        socket.destroy();
        return null;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      final c = _H2Conn(socket, ClientTransportConnection.viaSocket(socket));
      _failures = 0;
      return c;
    } catch (_) {
      _failures++;
      try {
        socket?.destroy();
      } catch (_) {}
      return null;
    }
  }
}

class _H2Conn {
  _H2Conn(this.socket, this.transport) {
    unawaited(socket.done.then<void>((_) {
      dead = true;
    }, onError: (Object _) {
      dead = true;
    }));
  }

  final SecureSocket socket;
  final ClientTransportConnection transport;
  bool dead = false;
  DateTime lastUsed = DateTime.now();
  bool _checking = false;

  bool get usable => !dead && transport.isOpen;

  /// A connection that sat idle for a while may have been dropped by the server or the Wi-Fi without telling us: ask it.
  Future<bool> alive() async {
    if (DateTime.now().difference(lastUsed) < const Duration(seconds: 15)) return true;
    try {
      await transport.ping().timeout(const Duration(seconds: 2));
      lastUsed = DateTime.now();
      return true;
    } catch (_) {
      kill();
      return false;
    }
  }

  /// After a request got no answer at all: is the connection itself dead? Only then is it dropped.
  Future<void> check() async {
    if (_checking || dead) return;
    _checking = true;
    try {
      await transport.ping().timeout(const Duration(seconds: 3));
    } catch (_) {
      kill();
    } finally {
      _checking = false;
    }
  }

  void kill() {
    dead = true;
    try {
      unawaited(transport.terminate().catchError((Object _) {}));
    } catch (_) {}
    try {
      socket.destroy();
    } catch (_) {}
  }

  Future<H2Reply?> get(Uri uri, Duration timeout) {
    final done = Completer<H2Reply?>();
    final body = BytesBuilder(copy: false);
    var status = 0;
    var expected = -1;
    var gotHeaders = false;
    Timer? limit;

    void finish(H2Reply? r) {
      if (done.isCompleted) return;
      limit?.cancel();
      done.complete(r);
    }

    ClientTransportStream? made;
    try {
      made = transport.makeRequest([
        Header.ascii(':method', 'GET'),
        Header.ascii(':scheme', 'https'),
        Header.ascii(':authority', uri.host),
        Header.ascii(':path', (uri.path.isEmpty ? '/' : uri.path) + (uri.hasQuery ? '?${uri.query}' : '')),
        Header.ascii('accept', 'image/*'),
      ], endStream: true);
    } catch (_) {}
    if (made == null) {
      kill();
      return Future.value(null);
    }
    final s = made;
    lastUsed = DateTime.now();

    limit = Timer(timeout, () {
      try {
        s.terminate(); // cancels this one request; the connection and the other pictures on it carry on
      } catch (_) {}
      final silent = !gotHeaders;
      finish(null);
      if (silent) unawaited(check());
    });

    s.incomingMessages.listen((m) {
      if (m is HeadersStreamMessage) {
        for (final h in m.headers) {
          final name = ascii.decode(h.name, allowInvalid: true);
          if (name == ':status') {
            status = int.tryParse(ascii.decode(h.value, allowInvalid: true)) ?? 0;
            gotHeaders = true;
          } else if (name == 'content-length') {
            expected = int.tryParse(ascii.decode(h.value, allowInvalid: true)) ?? -1;
          }
        }
      } else if (m is DataStreamMessage) {
        body.add(m.bytes);
      }
    }, onError: (Object _) {
      finish(null);
    }, onDone: () {
      lastUsed = DateTime.now();
      if (status == 0 || (expected >= 0 && body.length != expected)) {
        finish(null); // no status, or cut short: never keep half a picture
        return;
      }
      finish((status: status, bytes: body.takeBytes()));
    }, cancelOnError: true);

    return done.future;
  }
}
