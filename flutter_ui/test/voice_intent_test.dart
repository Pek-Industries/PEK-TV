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
  test('season and episode but no title: the app has to ask', () {
    final i = parseVoice('Play season 1 episode 2');
    expect(i.kind, VoiceKind.play);
    expect(i.text, '');
    expect(i.season, 1);
    expect(i.episode, 2);
    expect(i.missingTitle, isTrue);
  });
  test('a bare verb also asks', () {
    expect(parseVoice('play').missingTitle, isTrue);
    expect(parseVoice('search').missingTitle, isTrue);
    expect(parseVoice('play the bear').missingTitle, isFalse);
  });
  test('the answer to "what series?"', () {
    expect(titleFromAnswer("It's The Bear"), 'the bear');
    expect(titleFromAnswer('The series is Severance.'), 'severance');
    expect(titleFromAnswer('the bear'), 'the bear');
  });

  group('season / episode as the speech model hears them', () {
    test('"see someone" is season one', () {
      final i = parseVoice('play severance and see someone episode 2');
      expect(i.kind, VoiceKind.play);
      expect(i.text, 'severance');
      expect(i.season, 1);
      expect(i.episode, 2);
    });
    test('homophones after season / episode', () {
      final i = parseVoice('play severance season to episode for');
      expect(i.season, 2);
      expect(i.episode, 4);
    });
    test('a title that merely contains "for" is left alone', () {
      final i = parseVoice('play bridge for terabithia');
      expect(i.text, 'bridge for terabithia');
      expect(i.season, 0);
    });
  });

  group('durations', () {
    test('digits and words', () {
      expect(parseDuration('3 minutes'), 180);
      expect(parseDuration('three minutes'), 180);
      expect(parseDuration('ninety seconds'), 90);
      expect(parseDuration('twenty one minutes'), 1260);
    });
    test('combined', () {
      expect(parseDuration('1 hour 20 minutes'), 4800);
      expect(parseDuration('3 minutes 30 seconds'), 210);
      expect(parseDuration('an hour and a half'), 5400);
      expect(parseDuration('two and a half minutes'), 150);
      expect(parseDuration('half an hour'), 1800);
    });
    test('no time in it', () {
      expect(parseDuration('the future'), isNull);
      expect(parseDuration(''), isNull);
    });
    test('shown back to the person', () {
      expect(voiceTime(185), '3:05');
      expect(voiceTime(3725), '1:02:05');
      expect(voiceSpan(30), '30 seconds');
      expect(voiceSpan(90), '1 minute 30 seconds');
    });
  });

  group('player commands', () {
    test('skip to a time', () {
      final i = parseVoice('skip to 3 minutes in for me');
      expect(i.kind, VoiceKind.seek);
      expect(i.secs, 180);
      expect(parseVoice('can you jump to an hour and a half').secs, 5400);
    });
    test('relative', () {
      expect(parseVoice('go back 30 seconds').secs, -30);
      expect(parseVoice('go back 30 seconds').kind, VoiceKind.skip);
      expect(parseVoice('skip ahead 1 minute').secs, 60);
      expect(parseVoice('skip 45 seconds').secs, 45);
      expect(parseVoice('rewind').secs, -10);
    });
    test('start over, pause', () {
      expect(parseVoice('start over').kind, VoiceKind.seek);
      expect(parseVoice('start over').secs, 0);
      expect(parseVoice('pause it please').kind, VoiceKind.pause);
    });
    test('a title that starts like a command is still a title', () {
      expect(parseVoice('back to the future').kind, VoiceKind.search);
      expect(parseVoice('back to the future').text, 'back to the future');
      expect(parseVoice('go to the movies').kind, VoiceKind.open);
    });
    test('bare play: asks in the library, unpauses in the player', () {
      expect(parseVoice('play').missingTitle, isTrue);
      expect(parseVoice('play', player: true).kind, VoiceKind.resume);
      expect(parseVoice('resume', player: true).kind, VoiceKind.resume);
    });
  });

  group('scenes need the online assistant', () {
    test('on their own', () {
      final i = parseVoice('skip to where the guy gets slapped');
      expect(i.kind, VoiceKind.scene);
      expect(i.scene, 'where the guy gets slapped');
      expect(i.needsOnline, isTrue);
    });
    test('"the part where"', () {
      expect(parseVoice('skip to the part where he says hello').scene, 'where he says hello');
    });
    test('after a play request: the episode still plays', () {
      final i = parseVoice('play severance and see someone episode 2 and skip to where the guy get slapped');
      expect(i.kind, VoiceKind.play);
      expect(i.text, 'severance');
      expect(i.season, 1);
      expect(i.episode, 2);
      expect(i.scene, 'where the guy get slapped');
      expect(i.needsOnline, isTrue);
    });
  });

  group('play and start at a time', () {
    test('words', () {
      final i = parseVoice('Play Severance season one episode two and skip to 3 minutes in');
      expect(i.kind, VoiceKind.play);
      expect(i.text, 'severance');
      expect(i.season, 1);
      expect(i.episode, 2);
      expect(i.secs, 180);
      expect(i.scene, '');
    });
  });

  group('guess flag', () {
    test('no command word: a guess', () {
      expect(parseVoice('tom hanks').guess, isTrue);
      expect(parseVoice('play the matrix').guess, isFalse);
      expect(parseVoice('find alien').guess, isFalse);
    });
  });
}
