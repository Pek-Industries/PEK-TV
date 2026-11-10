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
  test('season and episode are split from the title', () {
    final i = parseVoice('Find Lioness episode 1 season 2');
    expect(i.kind, VoiceKind.search);
    expect(i.text, 'lioness');
    expect(i.season, 2);
    expect(i.episode, 1);
    expect(i.full, 'lioness episode 1 season 2');
  });
  test('season and episode in the other order, and as words', () {
    final i = parseVoice('play the bear season two episode three');
    expect(i.text, 'the bear');
    expect(i.season, 2);
    expect(i.episode, 3);
  });
  test('s2 e1 and "of"', () {
    expect(parseVoice('find severance s2 e1').text, 'severance');
    final i = parseVoice('play episode 4 of severance');
    expect(i.text, 'severance');
    expect(i.episode, 4);
    expect(i.season, 0);
  });
  test('a plain title is left alone', () {
    final i = parseVoice('find the matrix');
    expect(i.text, 'the matrix');
    expect(i.season, 0);
  });
}
