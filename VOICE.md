# Voice search and spoken replies

**Speech to text is bundled in the APK**: Moonshine tiny (English, int8) runs on the device through sherpa-onnx, so the mic works
on the first tap, offline, with no download. **Spoken replies are optional**: a Piper voice is downloaded from Cloudflare only if you
offer it; until then the app answers silently (it still searches / opens).

## Which recognizer runs

1. **The phone's own recognizer** (the engine behind the Google keyboard's mic), through `SpeechRecognizer` in `FlutterHostActivity.setupSystemVoice`
   and channel `pek/voice`. Best accuracy, live words, nothing to ship. Needs Google's speech service on the device (Google TV and most phones
   have it; some TV boxes do not). Audio may go to Google unless the device has its offline language pack, so mention it in your privacy text.
2. **The bundled Moonshine model** when 1 is missing or errors (for example offline without a language pack): lower accuracy, no live words.

## Bundled speech model

Shared by all platforms. Fetched at build time (not committed) by `tools/fetch-voice-model.sh`, which the GitHub workflow runs and caches.
For a local build run `bash tools/fetch-voice-model.sh` once. It fills the repo's top-level `assets/bundled/voice/stt/`:

```
assets/bundled/voice/stt/preprocess.onnx
assets/bundled/voice/stt/encode.int8.onnx
assets/bundled/voice/stt/uncached_decode.int8.onnx
assets/bundled/voice/stt/cached_decode.int8.onnx
assets/bundled/voice/stt/tokens.txt
```

Source: `sherpa-onnx-moonshine-tiny-en-int8.tar.bz2` from the sherpa-onnx `asr-models` release. Check its licence before shipping.
On Android, `app/build.gradle` adds `assets/bundled` to the APK's assets, keeps `.onnx` uncompressed and warns when the files are missing.
Another platform only needs to ship the same folder and copy it to `<app data>/voice/stt/` (see `VoiceModels.ensureBundled`).
On first use `FlutterHostActivity.copyBundledVoice` copies them to `<app files>/voice/stt/` (sherpa needs real file paths), then
writes `stt-ready.json` with `VoiceModels.bundledVersion`. **Change that version string whenever you change the model**, so devices re-copy.
The model therefore takes its size twice on disk (inside the APK, and the copy).

## Optional spoken replies: Cloudflare layout (R2 bucket, public via `models.pekindustries.com`)

```
voice/v1/manifest.json
voice/v1/tts/voice.onnx            (a Piper voice, e.g. en_US-lessac-medium.onnx, renamed)
voice/v1/tts/tokens.txt            (from the sherpa-onnx build of that voice)
voice/v1/tts/espeak-ng-data.zip    (the espeak-ng-data folder, zipped; English-only data is enough and much smaller)
```

Any `stt/` entries in the manifest are ignored. `manifest.json` (sha256 of each file as hex; `size` in bytes drives a progress bar):

```json
{ "version": 1, "files": [
  { "path": "tts/voice.onnx",                "size": 0, "sha256": "..." },
  { "path": "tts/tokens.txt",                "size": 0, "sha256": "..." },
  { "path": "tts/espeak-ng-data.zip",        "size": 0, "sha256": "...", "unzipTo": "tts/espeak-ng-data" }
] }
```

Cache headers: `Cache-Control: public, max-age=31536000, immutable` on the files, short on the manifest.
To ship a new voice, upload under `voice/v2/` and change `VoiceModels.base`.

## Code

- `voice_models.dart`: `ensureBundled` (copy the APK model), `sttReady` / `ttsReady`, optional Piper download with SHA-256 check, `.part` then rename, unzip, delete.
- `voice.dart`: record (16 kHz, stops after 0.9 s of quiet), Moonshine, `parseVoice`, Piper (only if downloaded), playback.
- `voice_mic.dart`: the mic button (listen, answer). Prepares the bundled model when it first appears. Used in `library_search.dart`.
- Android: `RECORD_AUDIO` is declared (it was stripped because of the Discord SDK); `micPermission` on `pek/host` asks at first use.

## Not done yet

- Open / Resume intents are parsed but only search and play-by-title are wired (in `LibrarySearchPanel`).
- Remote's mic key (`KEYCODE_SEARCH`) is not hooked; on Google TV that key goes to Google Assistant anyway.
- Ducking the video while the voice speaks.
- Not compiled or run: no Flutter SDK was available. Run `flutter pub get && flutter analyze && flutter test`, and
  check the sherpa_onnx constructor names against the version pub resolves (they change between releases): in particular `OfflineMoonshineModelConfig(preprocessor, encoder, uncachedDecoder, cachedDecoder)`.
- Not compiled or run either: the Kotlin copy (`installVoice`), the gradle `androidResources { noCompress }` line, and the workflow step.
- No UI yet to offer the optional spoken-reply download (`VoiceModels.download`) or to delete it.
