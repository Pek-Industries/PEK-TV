import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Where the voice models come from and where they live on the device.
///
/// Nothing is bundled in the APK. The first time someone taps the mic, [VoiceModels.download] fetches
/// `<base>/manifest.json` from Cloudflare (R2), downloads each file it lists, checks its SHA-256 and unpacks zips.
/// See VOICE.md for the manifest format and the files to upload.
class VoiceModels {
  /// An R2 bucket behind a custom domain (or a Worker in front of it). Change it here only.
  static const base = 'https://models.pekindustries.com/voice/v1';

  /// Fixed names inside the voice folder. The manifest must produce exactly these.
  static const sttEncoder = 'stt/tiny.en-encoder.int8.onnx';
  static const sttDecoder = 'stt/tiny.en-decoder.int8.onnx';
  static const sttTokens = 'stt/tiny.en-tokens.txt';
  static const ttsModel = 'tts/voice.onnx';
  static const ttsTokens = 'tts/tokens.txt';
  static const ttsEspeak = 'tts/espeak-ng-data'; // a folder, made from tts/espeak-ng-data.zip

  static const _marker = 'ready.json';

  static Future<Directory> root() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/voice');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Absolute path of one of the names above.
  static Future<String> path(String rel) async => '${(await root()).path}/$rel';

  /// True when every model file is there and was fully downloaded.
  static Future<bool> ready() async {
    try {
      final m = File(await path(_marker));
      if (!await m.exists()) return false;
      for (final f in [sttEncoder, sttDecoder, sttTokens, ttsModel, ttsTokens]) {
        if (!await File(await path(f)).exists()) return false;
      }
      return await Directory(await path(ttsEspeak)).exists();
    } catch (_) {
      return false;
    }
  }

  /// Removes the models (Settings > "Delete voice models").
  static Future<void> delete() async {
    final d = await root();
    if (await d.exists()) await d.delete(recursive: true);
  }

  /// Downloads everything. [onProgress] gets 0..1. Throws [VoiceDownloadException] with a message fit to show.
  /// A failed or cancelled download leaves nothing half-installed: files are written as *.part and renamed after the hash matches.
  static Future<void> download({void Function(double)? onProgress, http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final res = await c.get(Uri.parse('$base/manifest.json')).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw VoiceDownloadException('The voice download is not available right now (${res.statusCode}).');
      final m = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final files = [for (final f in (m['files'] as List)) VoiceFile.fromJson(f as Map<String, dynamic>)];
      final total = files.fold<int>(0, (a, f) => a + f.size);
      var done = 0;
      final root = await VoiceModels.root();
      for (final f in files) {
        final target = File('${root.path}/${f.path}');
        await target.parent.create(recursive: true);
        final part = File('${target.path}.part');
        final sink = part.openWrite();
        final digest = _DigestSink();
        final hasher = sha256.startChunkedConversion(digest);
        try {
          final req = http.Request('GET', Uri.parse('$base/${f.path}'));
          final resp = await c.send(req).timeout(const Duration(seconds: 30));
          if (resp.statusCode != 200) throw VoiceDownloadException('Could not download ${f.path} (${resp.statusCode}).');
          await for (final chunk in resp.stream.timeout(const Duration(seconds: 30))) {
            sink.add(chunk);
            hasher.add(chunk);
            done += chunk.length;
            if (total > 0) onProgress?.call((done / total).clamp(0.0, 1.0));
          }
          await sink.flush();
          await sink.close();
          hasher.close();
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {}
          if (await part.exists()) await part.delete();
          if (e is VoiceDownloadException) rethrow;
          throw VoiceDownloadException('The download was interrupted. Check the connection and try again.');
        }
        if (f.sha256.isNotEmpty && digest.value.toString() != f.sha256.toLowerCase()) {
          await part.delete();
          throw VoiceDownloadException('${f.path} did not download correctly. Try again.');
        }
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        if (f.unzipTo != null) {
          final out = '${root.path}/${f.unzipTo}';
          if (await Directory(out).exists()) await Directory(out).delete(recursive: true);
          await extractFileToDisk(target.path, out);
          await target.delete();
        }
      }
      await File('${root.path}/$_marker').writeAsString(jsonEncode({'version': m['version'], 'at': DateTime.now().toIso8601String()}));
    } finally {
      if (client == null) c.close();
    }
  }
}

class VoiceFile {
  const VoiceFile({required this.path, required this.size, required this.sha256, this.unzipTo});
  final String path; // relative to `base` and to the voice folder
  final int size;
  final String sha256;
  final String? unzipTo; // folder to unpack a .zip into (the zip is deleted afterwards)

  factory VoiceFile.fromJson(Map<String, dynamic> j) {
    final p = (j['path'] ?? '').toString();
    // The manifest is ours, but never let a path leave the voice folder.
    if (p.isEmpty || p.startsWith('/') || p.contains('..') || p.contains('\\')) {
      throw VoiceDownloadException('The voice list is not valid.');
    }
    final u = j['unzipTo']?.toString();
    if (u != null && (u.startsWith('/') || u.contains('..'))) throw VoiceDownloadException('The voice list is not valid.');
    return VoiceFile(path: p, size: (j['size'] as num?)?.toInt() ?? 0, sha256: (j['sha256'] ?? '').toString(), unzipTo: u);
  }
}

class VoiceDownloadException implements Exception {
  VoiceDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest d) => value = d;
  @override
  void close() {}
}
