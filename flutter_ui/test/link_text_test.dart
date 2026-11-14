import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/link_text.dart';

void main() {
  test('finds web addresses, bare domains and e-mail addresses', () {
    const t = 'See https://pekindustries.com/pektv/account, or pekindustries.com/pektv. Mail r3ct.info@gmail.com!';
    final l = Links.find(t);
    expect(l.map((e) => e.$3).toList(), ['https://pekindustries.com/pektv/account', 'https://pekindustries.com/pektv', 'mailto:r3ct.info@gmail.com']);
    // trailing punctuation stays outside the link
    expect(t.substring(l[0].$1, l[0].$2), 'https://pekindustries.com/pektv/account');
  });

  test('file names are not links', () {
    expect(Links.find('Edit backend.py and ui.js, then run plugin.json'), isEmpty);
  });
}
