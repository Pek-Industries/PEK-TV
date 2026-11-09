import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/voice.dart';

void main() {
  test('play', () {
    final i = parseVoice('Play The Matrix.');
    expect(i.kind, VoiceKind.play);
    expect(i.text, 'the matrix');
  });
  test('wake word and politeness are dropped', () {
    expect(parseVoice('Hey Pek TV, can you play Alien').text, 'alien');
  });
  test('open a page', () {
    final i = parseVoice('Open TV shows');
    expect(i.kind, VoiceKind.open);
    expect(i.text, 'shows');
  });
  test('resume', () => expect(parseVoice('Resume watching').kind, VoiceKind.resume));
  test('anything else is a search', () => expect(parseVoice('tom hanks').kind, VoiceKind.search));
  test('silence', () => expect(parseVoice('  ').kind, VoiceKind.unknown));
}
