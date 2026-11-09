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
  const VoiceIntent(this.kind, [this.text = '']);
  final VoiceKind kind;

  /// The title for play / search, the place for open ('movies', 'shows', 'music', 'settings', 'home').
  final String text;
  @override
  String toString() => 'VoiceIntent($kind, "$text")';
}

/// Turns the words Whisper heard into an [VoiceIntent]. Pure: no I/O, easy to test.
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
  if (play != null) return VoiceIntent(VoiceKind.play, play.group(3)!.trim());
  final find = RegExp(r'^(search for|search|find|look for|look up) (the )?(.+)$').firstMatch(t);
  if (find != null) return VoiceIntent(VoiceKind.search, find.group(3)!.trim());
  return VoiceIntent(VoiceKind.search, t); // anything else is treated as something to look for
}

/// Record -> Whisper tiny.en -> intent, and Piper -> speaker. Models come from [VoiceModels]; nothing is loaded until used.
///
/// Whisper and Piper run in a short-lived isolate each call (Isolate.run), so the UI never stutters. The model files are
/// read again every call (tiny is quick); keep one isolate alive instead if this turns out too slow on a weak box.
class Voice {
  Voice._();
  static final Voice instance = Voice._();

  static const _host = MethodChannel('pek/host');
  static const _rate = 16000;

  final AudioRecorder _rec = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  bool _busy = false;
  bool get busy => _busy;

  /// Asks Android for the microphone (the first time only shows the system box).
  Future<bool> micAllowed() async {
    try {
      return (await _host.invokeMethod<bool>('micPermission')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Listens until the person stops talking (or [maxSeconds]), returns what was said. '' = nothing heard.
  Future<String> listen({int maxSeconds = 7, void Function(double level)? onLevel}) async {
    if (_busy) return '';
    _busy = true;
    try {
      if (!await micAllowed()) throw VoiceException('Allow the microphone to use voice search.');
      final stream = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _rate, numChannels: 1));
      final pcm = BytesBuilder(copy: false);
      var spoke = false;
      var quietMs = 0;
      var totalMs = 0;
      final done = Completer<void>();
      late StreamSubscription<Uint8List> sub;
      sub = stream.listen((chunk) {
        pcm.add(chunk);
        final ms = chunk.length * 1000 ~/ (_rate * 2);
        totalMs += ms;
        final level = _rms(chunk);
        onLevel?.call(level);
        if (level > 0.02) {
          spoke = true;
          quietMs = 0;
        } else {
          quietMs += ms;
        }
        final noSpeech = !spoke && totalMs > 4000;
        final finished = spoke && quietMs > 900;
        if ((noSpeech || finished || totalMs > maxSeconds * 1000) && !done.isCompleted) done.complete();
      });
      await done.future;
      await sub.cancel();
      await _rec.stop();
      if (!spoke) return '';
      return await _transcribe(pcm.takeBytes());
    } finally {
      _busy = false;
    }
  }

  /// Stops a listen() that is running.
  Future<void> cancel() async {
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
    final enc = await VoiceModels.path(VoiceModels.sttEncoder);
    final dec = await VoiceModels.path(VoiceModels.sttDecoder);
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
          whisper: sherpa.OfflineWhisperModelConfig(encoder: enc, decoder: dec, language: 'en', task: 'transcribe'),
          tokens: tok,
          modelType: 'whisper',
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
    if (text.trim().isEmpty) return;
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
