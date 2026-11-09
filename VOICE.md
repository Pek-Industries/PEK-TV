# Voice search and spoken replies

Whisper tiny.en (speech to text) and a Piper voice (text to speech) run on the device through sherpa-onnx. **Nothing is bundled.**
The first tap on the mic asks, then downloads the models from Cloudflare.

## Cloudflare layout (R2 bucket, public via `models.pekindustries.com`)

```
voice/v1/manifest.json
voice/v1/stt/tiny.en-encoder.int8.onnx
voice/v1/stt/tiny.en-decoder.int8.onnx
voice/v1/stt/tiny.en-tokens.txt
voice/v1/tts/voice.onnx            (a Piper voice, e.g. en_US-lessac-medium.onnx, renamed)
voice/v1/tts/tokens.txt            (from the sherpa-onnx build of that voice)
voice/v1/tts/espeak-ng-data.zip    (the espeak-ng-data folder, zipped)
```

`manifest.json` (sha256 of each file as hex; `size` in bytes drives the progress bar):

```json
{ "version": 1, "files": [
  { "path": "stt/tiny.en-encoder.int8.onnx", "size": 0, "sha256": "..." },
  { "path": "stt/tiny.en-decoder.int8.onnx", "size": 0, "sha256": "..." },
  { "path": "stt/tiny.en-tokens.txt",        "size": 0, "sha256": "..." },
  { "path": "tts/voice.onnx",                "size": 0, "sha256": "..." },
  { "path": "tts/tokens.txt",                "size": 0, "sha256": "..." },
  { "path": "tts/espeak-ng-data.zip",        "size": 0, "sha256": "...", "unzipTo": "tts/espeak-ng-data" }
] }
```

Get the Whisper and Piper files from the sherpa-onnx model releases (`sherpa-onnx-whisper-tiny.en`, `vits-piper-en_US-*`).
Check their licences before hosting them. Cache headers: `Cache-Control: public, max-age=31536000, immutable` on the files, short on the manifest.
To ship a new voice, upload under `voice/v2/` and change `VoiceModels.base`.

## Code

- `voice_models.dart`: manifest, download with progress, SHA-256 check, `.part` then rename, unzip, delete.
- `voice.dart`: record (16 kHz, stops after 0.9 s of quiet), Whisper, `parseVoice`, Piper, playback.
- `voice_mic.dart`: the mic button (ask, download, listen, answer). Used in `library_search.dart`.
- Android: `RECORD_AUDIO` is declared (it was stripped because of the Discord SDK); `micPermission` on `pek/host` asks at first use.

## Not done yet

- Open / Resume intents are parsed but only search and play-by-title are wired (in `LibrarySearchPanel`).
- Remote's mic key (`KEYCODE_SEARCH`) is not hooked; on Google TV that key goes to Google Assistant anyway.
- Ducking the video while the voice speaks.
- Not compiled or run: no Flutter SDK was available. Run `flutter pub get && flutter analyze && flutter test`, and
  check the sherpa_onnx constructor names against the version pub resolves (they change between releases).
