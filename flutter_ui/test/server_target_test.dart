import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/server_target.dart';

void main() {
  test('typed addresses become a base address', () {
    expect(ServerTarget.normalize('192.168.1.20'), 'http://192.168.1.20:8080');
    expect(ServerTarget.normalize(' 192.168.1.20:9000 '), 'http://192.168.1.20:9000');
    expect(ServerTarget.normalize('nas.local'), 'http://nas.local:8080');
    expect(ServerTarget.normalize('http://192.168.1.20:8080/'), 'http://192.168.1.20:8080');
    expect(ServerTarget.normalize('http://192.168.1.20'), 'http://192.168.1.20'); // a scheme without a port keeps the scheme's port
    expect(ServerTarget.normalize('https://pek.example.com/pek/'), 'https://pek.example.com/pek');
    expect(ServerTarget.normalize(''), '');
    expect(ServerTarget.normalize('   '), '');
  });

  test('only internet addresses without https count as not private', () {
    expect(ServerTarget.insecure('http://192.168.1.20:8080'), false);
    expect(ServerTarget.insecure('http://10.0.0.5:8080'), false);
    expect(ServerTarget.insecure('http://172.20.1.1:8080'), false);
    expect(ServerTarget.insecure('http://100.101.102.103:8080'), false); // Tailscale
    expect(ServerTarget.insecure('http://nas.local:8080'), false);
    expect(ServerTarget.insecure('http://box.tail1234.ts.net:8080'), false);
    expect(ServerTarget.insecure('https://pek.example.com'), false);
    expect(ServerTarget.insecure('http://pek.example.com'), true);
    expect(ServerTarget.insecure('http://203.0.113.9:8080'), true);
  });
}
