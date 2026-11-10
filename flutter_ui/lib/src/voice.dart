import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'voice_models.dart';

/// What a spoken sentence asks for.
enum VoiceKind { play, search, open, resume, unknown }

class VoiceIntent {
  const VoiceIntent(this.kind, [this.text = '', this.season = 0, this.episode = 0, this._full]);
  final VoiceKind kind;

  /// The title for play / search, the place for open ('movies', 'shows', 'music', 'settings', 'home').
  /// For a show this is the title alone: "lioness season 2 episode 1" gives 'lioness'.
  final String text;

  /// The season / episode that was spoken, 0 = not said.
  final int season, episode;
  final String? _full;

  /// [text] exactly as spoken, season and episode words included. A movie called "Star Wars Episode 1" needs this one.
  String get full => _full ?? text;
  @override
  String toString() => 'VoiceIntent($kind, "$text"${season > 0 ? ', S$season' : ''}${episode > 0 ? ', E$episode' : ''})';
}

const _numberWords = {
  'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10,
  'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14, 'fifteen': 15, 'sixteen': 16, 'seventeen': 17, 'eighteen': 18,
  'nineteen': 19, 'twenty': 20, 'first': 1, 'second': 2, 'third': 3, 'fourth': 4, 'fifth': 5, 'sixth': 6, 'seventh': 7,
  'eighth': 8, 'ninth': 9, 'tenth': 10,
};
const _numPat = r'(\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)';
int _numOf(String s) => int.tryParse(s) ?? _numberWords[s] ?? 0;

/// "lioness episode 1 season 2" -> ('lioness', 2, 1). Also "season two", "s2 e1", "episode 3 of lioness".
({String title, int season, int episode}) splitSeasonEpisode(String t) {
  var season = 0, episode = 0;
  t = t.replaceFirstMapped(RegExp(r'\bs(\d{1,2}) ?e(\d{1,3})\b'), (m) {
    season = int.parse(m.group(1)!);
    episode = int.parse(m.group(2)!);
    return ' ';
  });
  t = t.replaceFirstMapped(RegExp('\\b(?:season|series) $_numPat\\b'), (m) {
    season = _numOf(m.group(1)!);
    return ' ';
  });
  t = t.replaceFirstMapped(RegExp('\\b(?:episode|ep) $_numPat\\b'), (m) {
    episode = _numOf(m.group(1)!);
    return ' ';
  });
  if (season == 0 && episode == 0) return (title: t, season: 0, episode: 0);
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceFirst(RegExp(r'^(of|in|from|for) '), '').replaceFirst(RegExp(r' (of|in|from|for)$'), '').trim();
  return (title: t, season: season, episode: episode);
}

VoiceIntent _titleIntent(VoiceKind kind, String raw) {
  final r = raw.trim();
  final s = splitSeasonEpisode(r);
  if (s.title.isEmpty) return VoiceIntent(kind, r); // only "season 2" was said: keep it as spoken
  return VoiceIntent(kind, s.title, s.season, s.episode, r);
}

/// Turns the words the speech model heard into an [VoiceIntent]. Pure: no I/O, easy to test.
VoiceIntent parseVoice(String heard) {
  var t = heard.toLowerCase().replaceAll(RegExp(r"[^a-z0-9' ]"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return const VoiceIntent(VoiceKind.unknown);
  t = t.replaceFirst(RegExp(r'^(hey |ok |okay )?(pek|peck|pec|pet)( tv)?[, ]*'), '');
  t = t.replaceFirst(RegExp(r'^(please |can you |could you )+'), '').trim();
  if (RegExp(r'^(resume|continue)( watching| playing| where i left off)?$').hasMatch(t)) return const VoiceIntent(VoiceKind.resume);
  final open = RegExp(r'^(open|go to|show me|show) (the )?(my )?(movies|shows|tv shows|music|settings|home|favorites|favourites)$').firstMatch(t);
  if (open != null) {
    var w = open.group(4)!;
    if (w == 'tv shows') w = 'shows';
    if (w == 'favourites') w = 'favorites';
    return VoiceIntent(VoiceKind.open, w);
  }
  final play = RegExp(r'^(play|watch|start|put on) (the movie |the show |the film |some )?(.+)$').firstMatch(t);
  if (play != null) return _titleIntent(VoiceKind.play, play.group(3)!);
  final find = RegExp(r'^(search for|search|find|look for|look up) (the )?(.+)$').firstMatch(t);
  if (find != null) return _titleIntent(VoiceKind.search, find.group(3)!);
  return _titleIntent(VoiceKind.search, t); // anything else is treated as something to look for
}

/// Record -> Moonshine tiny (bundled) -> intent, and Piper (optional download) -> speaker. Models come from [VoiceModels]; nothing is loaded until used.
///
/// Moonshine and Piper run in a short-lived isolate each call (Isolate.run), so the UI never stutters. The model files are
/// read again every call (tiny is quick); keep one isolate alive instead if this turns out too slow on a weak box.
class Voice {
  Voice._();
  static final Voice instance = Voice._();

  static const _host = MethodChannel('pek/host');
  static const _sys = MethodChannel('pek/voice'); // the phone's own recognizer (FlutterHostActivity.setupSystemVoice)
  static const _rate = 16000;

  // How long a pause ends the listening. Short on purpose: there is no OK button on a phone.
  static const _sysQuietMs = 700; // phone recognizer: no new words for this long, after some were heard
  static const _sysNoSpeechMs = 3000; // phone recognizer: nothing heard at all
  static const _endQuietMs = 600; // bundled model: quiet for this long after speech
  static const _noSpeechMs = 3000; // bundled model: no speech at all

  final AudioRecorder _rec = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  bool _busy = false;
  bool _cancelled = false;
  Completer<void>? _done;
  bool _sysActive = false;
  bool get busy => _busy;

  /// Asks Android for the microphone (the first time only shows the system box).
  Future<bool> micAllowed() async {
    try {
      return (await _host.invokeMethod<bool>('micPermission')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The phone's own recognizer (the Google keyboard's engine): live words through [onPartial], no model to ship.
  /// Returns null when it is not usable here (no recognizer, offline without a language pack, ...): the caller then uses the bundled model.
  Future<String?> _listenSystem({void Function(double level)? onLevel, void Function(String text)? onPartial, List<String> bias = const []}) async {
    try {
      if (!(await _sys.invokeMethod<bool>('available') ?? false)) return null;
    } catch (_) {
      return null;
    }
    // The engine's own end-of-speech wait is slow and varies by device, so stop it ourselves as soon as the words stop changing.
    final started = DateTime.now();
    var lastChange = started;
    var last = '';
    var gotWords = false;
    var stopped = false;
    final watchdog = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (stopped) return;
      final now = DateTime.now();
      final quiet = now.difference(lastChange).inMilliseconds;
      if ((gotWords && quiet > _sysQuietMs) || (!gotWords && now.difference(started).inMilliseconds > _sysNoSpeechMs)) {
        stopped = true;
        _sys.invokeMethod<void>('stop');
      }
    });
    _sys.setMethodCallHandler((c) async {
      if (c.method == 'partial') {
        final t = c.arguments as String;
        if (t != last) {
          last = t;
          lastChange = DateTime.now();
          gotWords = true;
        }
        onPartial?.call(t);
      }
      if (c.method == 'level') onLevel?.call((c.arguments as num).toDouble());
    });
    _sysActive = true;
    try {
      return await _sys.invokeMethod<String>('start', {'bias': bias}) ?? '';
    } on PlatformException {
      return null;
    } finally {
      watchdog.cancel();
      _sysActive = false;
      _sys.setMethodCallHandler(null);
    }
  }

  /// Listens until the person stops talking (or [maxSeconds]), returns what was said. '' = nothing heard.
  /// [onLevel] gets 0..1 (how loud). [onPartial] gets the words so far, live, when the phone's own recognizer is used.
  /// [bias] are titles to expect; the phone's recognizer (Android 13+) uses them to hear names correctly.
  Future<String> listen({int maxSeconds = 7, void Function(double level)? onLevel, void Function(String text)? onPartial, List<String> bias = const []}) async {
    if (_busy) return '';
    _busy = true;
    _cancelled = false;
    try {
      if (!await micAllowed()) throw VoiceException('Allow the microphone to use voice search.');
      final sys = await _listenSystem(onLevel: onLevel, onPartial: onPartial, bias: bias);
      if (sys != null) return _cancelled ? '' : sys.trim();
      // No usable system recognizer: the bundled model (it hears the whole sentence first, so no live words).
      if (!await VoiceModels.ensureBundled()) throw VoiceException('Voice search is not included in this build.');
      final stream = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _rate, numChannels: 1));
      final pcm = BytesBuilder(copy: false);
      var spoke = false;
      var quietMs = 0;
      var totalMs = 0;
      final done = Completer<void>();
      _done = done;
      late StreamSubscription<Uint8List> sub;
      sub = stream.listen((chunk) {
        pcm.add(chunk);
        final ms = chunk.length * 1000 ~/ (_rate * 2);
        totalMs += ms;
        final level = _rms(chunk);
        onLevel?.call((level * 8).clamp(0.0, 1.0));
        if (level > 0.02) {
          spoke = true;
          quietMs = 0;
        } else {
          quietMs += ms;
        }
        final noSpeech = !spoke && totalMs > _noSpeechMs;
        final finished = spoke && quietMs > _endQuietMs;
        if ((noSpeech || finished || totalMs > maxSeconds * 1000) && !done.isCompleted) done.complete();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      });
      await done.future;
      await sub.cancel();
      await _rec.stop();
      if (_cancelled || !spoke) return '';
      return await _transcribe(pcm.takeBytes());
    } finally {
      _done = null;
      _busy = false;
    }
  }

  /// Ends the listening now and still works out what was said (the person tapped OK / the orb).
  void finish() {
    if (_sysActive) {
      _sys.invokeMethod<void>('stop');
      return;
    }
    final d = _done;
    if (d != null && !d.isCompleted) d.complete();
  }

  /// Stops a listen() that is running and throws the recording away.
  Future<void> cancel() async {
    _cancelled = true;
    if (_sysActive) {
      try {
        await _sys.invokeMethod<void>('cancel');
      } catch (_) {}
      return;
    }
    final d = _done;
    if (d != null && !d.isCompleted) d.complete();
    try {
      await _rec.stop();
    } catch (_) {}
  }

  static double _rms(Uint8List b) {
    final n = b.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.sublistView(b);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return math.sqrt(sum / n);
  }

  Future<String> _transcribe(Uint8List pcm16) async {
    final pre = await VoiceModels.path(VoiceModels.sttPreprocess);
    final enc = await VoiceModels.path(VoiceModels.sttEncoder);
    final unc = await VoiceModels.path(VoiceModels.sttUncachedDecoder);
    final cac = await VoiceModels.path(VoiceModels.sttCachedDecoder);
    final tok = await VoiceModels.path(VoiceModels.sttTokens);
    return Isolate.run(() {
      sherpa.initBindings();
      final samples = Float32List(pcm16.length ~/ 2);
      final bd = ByteData.sublistView(pcm16);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      final rec = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          moonshine: sherpa.OfflineMoonshineModelConfig(preprocessor: pre, encoder: enc, uncachedDecoder: unc, cachedDecoder: cac),
          tokens: tok,
          numThreads: 2,
          debug: false,
        ),
      ));
      final s = rec.createStream();
      s.acceptWaveform(samples: samples, sampleRate: _rate);
      rec.decode(s);
      final text = rec.getResult(s).text.trim();
      s.free();
      rec.free();
      return text;
    });
  }

  /// Says [text] out loud with the Piper voice. Keep it to a sentence.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty || !await VoiceModels.ttsReady()) return; // spoken replies are optional: silent until the voice is downloaded
    final model = await VoiceModels.path(VoiceModels.ttsModel);
    final tokens = await VoiceModels.path(VoiceModels.ttsTokens);
    final data = await VoiceModels.path(VoiceModels.ttsEspeak);
    final r = await Isolate.run(() {
      sherpa.initBindings();
      final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(model: model, tokens: tokens, dataDir: data),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
        maxNumSenetences: 1, // (sic) the package spells it this way
      ));
      final audio = tts.generate(text: text, sid: 0, speed: 1.0);
      final out = (audio.samples, audio.sampleRate);
      tts.free();
      return out;
    });
    final wav = _wav(r.$1, r.$2);
    final done = Completer<void>();
    final sub = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    await _player.play(BytesSource(wav));
    await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    await sub.cancel();
  }

  static Uint8List _wav(Float32List samples, int rate) {
    final data = ByteData(44 + samples.length * 2);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    str(8, 'WAVEfmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    str(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

class VoiceException implements Exception {
  VoiceException(this.message);
  final String message;
  @override
  String toString() => message;
}
