# Discord Rich Presence (shows what you are watching on your Discord profile)

A profile that links Discord shows "Watching <title>" (with the elapsed time) on its Discord profile while a movie or an episode
plays. Android only for now. Settings > Account > Discord (regular mode, not music mode):

- **Phone / tablet:** a "Link Discord" button (it follows the skin). It opens Discord's approval page; tap Authorize and come back.
- **TV:** "Link Discord with a QR code". Scan it with a phone, tap Authorize.
- Afterwards: "Show what I am watching" (on / off), "Show titles" (off = Discord only says "Watching on PEK TV"), "Unlink Discord".
- Every profile links its own Discord account. Nothing is shared until a profile links, and only movies and episodes are shown
  (a torrent without a movie / episode identity never is).

## How it works

```
TV / phone ──POST /v1/discord/start──▶ PEK cloud worker      (link + secret `poll` value)
person opens link ─▶ /v1/discord/go ─▶ discord.com/oauth2/authorize ─▶ /v1/discord/callback
                      (the worker swaps the code for tokens with the client secret and keeps them for at most 10 minutes)
app ──POST /v1/discord/poll──▶ gets the tokens ONCE (the row is deleted as it is read)
app ─▶ pek/discord channel ─▶ FlutterDiscord.kt ─▶ NativeDiscord.kt ─▶ discord_presence.cpp ─▶ Discord Social SDK
```

- Tokens last about 7 days. The app swaps its refresh token for a new pair at `/v1/discord/refresh` when less than a day is left.
- What is playing never goes to the PEK cloud. The SDK on the device tells Discord directly.
- Tokens are kept on the device only, under `pek_discord_<profile id>` (device-wide, not in the synced profile keys).
- Scopes: `openid sdk.social_layer_presence` (Discord's "default presence scopes").

## Setting it up

1. **Discord application.** https://discord.com/developers/applications -> your application (call it **PEK TV**: that is the name Discord
   shows). Note the Application ID and, under OAuth2, the Client Secret.
2. **Redirect.** OAuth2 -> Redirects -> add `https://pek-sync.aquariusibeats.workers.dev/v1/discord/callback` (your worker's address
   if it differs, then the same address in `Cloud.api`).
3. **Cloud worker.** Paste the new `cloud/worker.js` and add: **Text** `DISCORD_CLIENT_ID` = the Application ID, **Secret**
   `DISCORD_CLIENT_SECRET` = the Client Secret. Deploy. (The `discord_links` table is created by itself.)
   Until these exist the app says "Discord linking is not turned on in the PEK cloud yet".
4. **Social SDK for Android.** In the application: Discord Social SDK -> Getting Started (fill in the form to switch it on) ->
   Downloads -> the Android package. Put its files here (the same idea as `android/libsmb2`):
   ```
   android/discord_social_sdk/include/discordpp.h
   android/discord_social_sdk/lib/arm64-v8a/<the .so>
   android/discord_social_sdk/lib/armeabi-v7a/<the .so>     (if the SDK ships 32-bit)
   ```
   CMake finds them by itself (`PEK: Discord Rich Presence ON` in the build log) and Gradle packs the `.so` files into the APK.
   Without them the app builds exactly as before and Settings says "built without Discord support". The CI workflow has to have these
   files too (a private repo, or a step that fetches them); the SDK is not allowed to be redistributed publicly.
5. Build and install.

## Tests

`sh tools/cloud-tests/run.sh` runs the link flow (start, approve, one-time pickup, expiry, refresh, revoke, rate limit) against a
real SQLite database with a fake Discord. It passes.

## NOT verified (I had no Flutter SDK, no Android SDK and no Discord SDK here)

- **The Dart code was never compiled or analysed.** Run `flutter analyze` first.
- **The `discordpp` calls in `discord_presence.cpp`** were written from Discord's public docs and only syntax-checked against a mock of
  that API. Check against the real `discordpp.h`: the names and signatures, whether `ActivityTypes::Watching` exists (else use
  Playing), whether timestamps are milliseconds, and whether Discord's Android guide asks for an init call (JavaVM / context) before
  the first `Client`. Every such spot is marked `TODO(verify)`.
- **Android TV:** the Social SDK documents Android 7.0+ but I found nothing that says leanback TV boxes are supported. Try a real box
  before relying on the QR flow.
- **A phone opening the link:** the link is on the worker's address, so it opens in the browser first and then goes to Discord; whether
  the Discord app takes over depends on the phone.
- **Presence while the app is in the background:** the connection is made when playback starts and cleared on stop; what Android does
  to it when the app is paused is untested.
- No poster / artwork is sent yet (Discord needs an uploaded asset or a URL it accepts).
- Google Play wants 16 KB-aligned native libraries: check that the SDK's `.so` is.
