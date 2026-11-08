import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/api.dart';

void main() {
  setUp(() => Api.token = 'abc123');
  tearDown(() => Api.token = '');

  test('headers carry the token for the local server only', () {
    expect(Api.headersFor('${Api.base}/api/status'), {'X-Pek-Token': 'abc123'});
    expect(Api.headersFor('https://image.tmdb.org/t/p/w500/x.jpg'), isEmpty);
    expect(Api.headersFor('http://127.0.0.1:8081/api/status'), isEmpty);
    expect(Api.headersFor('http://127.0.0.1:8080.evil.example/x'), isEmpty);
  });

  test('withToken adds ?pek_t= or &pek_t= to local addresses only', () {
    expect(Api.withToken('${Api.base}/api/stream/7'), '${Api.base}/api/stream/7?pek_t=abc123');
    expect(Api.withToken('${Api.base}/api/music/art?album=3'), '${Api.base}/api/music/art?album=3&pek_t=abc123');
    expect(Api.withToken('https://example.com/a.jpg'), 'https://example.com/a.jpg');
  });

  test('withToken puts the token on every file of an edl:// address', () {
    final joined = 'edl://${Api.base}/api/stream/1;${Api.base}/api/stream/2';
    expect(Api.withToken(joined), 'edl://${Api.base}/api/stream/1?pek_t=abc123;${Api.base}/api/stream/2?pek_t=abc123');
  });

  test('no token (tests, desktop) leaves addresses and headers alone', () {
    Api.token = '';
    expect(Api.withToken('${Api.base}/api/stream/7'), '${Api.base}/api/stream/7');
    expect(Api.headersFor('${Api.base}/api/status'), isEmpty);
  });
}
