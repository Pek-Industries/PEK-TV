import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/api.dart';

void main() {
  test('several files of one movie become one edl:// address, in order', () {
    final url = Api.joinedStreamUrl(['aaa', 'bbb']);
    expect(url, 'edl://${Api.streamUrl('aaa')};${Api.streamUrl('bbb')}');
    expect(url.startsWith('edl://http://'), true);
  });
}
