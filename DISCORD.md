# Discord Rich Presence (shows what you are watching on your Discord profile)

A profile that links Discord shows "Watching" and the title (with the elapsed time) on its Discord profile while a movie or an episode
plays. Android only for now. Settings > Account > Discord (regular mode, not music mode):

- **Phone / tablet:** a "Link Discord" button (it follows the skin). It opens Discord's approval page; tap Authorize and come back.
- **TV:** "Link Discord with a QR code". Scan it with a phone, tap Authorize.
- Afterwards: "Show what I am watching" (on / off), "Show titles" (off = Discord only says "Watching on PEK TV"), "Unlink Discord".
- Every profile links its own Discord account. Nothing is shared until a profile links, and only movies and episodes are shown
  (a torrent without a movie / episode identity never is).

## How it works

```
TV / phone ──POST /v1/discord/start──▶ PEK cloud worker      (needs the PEK session token; link + secret `poll` value)
person opens link ─▶ /v1/discord/go ─▶ discord.com/oauth2/authorize ─▶ /v1/discord/callback
                      (the worker swaps the code for tokens with the client secret and keeps them for at most 10 minutes)
app ──POST /v1/discord/poll──▶ gets the tokens ONCE (the row is deleted as it is read)
app ─▶ pek/discord channel ─▶ FlutterDiscord.kt ─▶ NativeDiscord.kt ─▶ discord_presence.cpp ─▶ Discord Social SDK
```

- **A signed-in PEK account is required.** `start`, `poll`, `refresh` and `revoke` all need the PEK session token (the worker answers 401
  `bad_session` without it), the `poll` secret only works for the account that started the link, and Settings shows "Sign in to your PEK
  account" instead of the link button while signed out. Signing out of PEK also stops presence. The phone that opens the approval link
  does not need to be signed in to PEK: the TV (or phone app) that started the link is.
- Tokens last about 7 days. The app swaps its refresh token for a new pair at `/v1/discord/refresh` when less than a day is left.
- What is playing never goes to the PEK cloud. The SDK on the device tells Discord directly.
- Tokens are kept on the device only, under `pek_discord_<profile id>` (device-wide, not in the synced profile keys).
- Scopes: `openid sdk.social_layer_presence` (Discord's "default presence scopes").

## Setting it up

1. **Discord application.** https://discord.com/developers/applications -> your application (call it **PEK TV**: that is the name Discord
   shows). Note the Application ID and, under OAuth2, the Client Secret.
2. **Redirect.** OAuth2 -> Redirects -> add `https://api.pekindustries.com/v1/discord/callback` (your worker's address
   if it differs, then the same address in `Cloud.api`).
3. **Cloud worker.** Update the sync worker and add: **Text** `DISCORD_CLIENT_ID` = the Application ID, **Secret**
   `DISCORD_CLIENT_SECRET` = the Client Secret. Deploy. (The `discord_links` table is created by itself.)
   Until these exist the app says "Discord linking is not turned on in the PEK cloud yet".
4. **Social SDK for Android.** In the application: Discord Social SDK (under **Games** in the portal menu) -> Getting Started (fill in
   the form to switch it on) -> Downloads -> `DiscordSocialSdk-<version>.zip` (the C++ one). Inside it, take **one file**:
   ```
   discord_social_sdk/lib/release/discord_partner_sdk.aar   ->   android/app/libs/discord_partner_sdk.aar
   ```
   (Not the `krisp` files: those are voice noise suppression. Not the `.so` files in the zip's `bin` or `lib` folders: those are
   desktop.) Gradle adds the `.aar` by itself and passes its headers on through Prefab, exactly as Discord's Android guide says; CMake
   then prints `PEK: Discord Rich Presence ON`. The `.aar` holds the arm64-v8a, armeabi-v7a, x86 and x86_64 builds, so both of your CPU
   builds get it. Without the file the app builds exactly as before and Settings says "built without Discord support".
   The file is committed to the repo (it is no longer in `.gitignore`), so CI builds include Discord support too.
5. Build and install.

## Tests

The worker's own test suite runs the link flow (start, approve, one-time pickup, expiry, refresh, revoke, rate limit) against a
real SQLite database with a fake Discord. It passes.

## Build changes this makes

- `android/app/build.gradle`: Prefab on, and the `.aar` as a dependency only if `android/app/libs/discord_partner_sdk.aar` exists.
- `AndroidManifest.xml`: the SDK's `.aar` adds voice chat permissions (microphone, Bluetooth, audio settings) and a voice service.
  PEK TV only shows presence, so they are removed again (`tools:node="remove"`); `FOREGROUND_SERVICE` and
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK` stay because the app declares them itself.
- `FlutterDiscord.kt` makes the SDK's one startup call (`DiscordSocialSdkInit.setEngineActivity`).
- The app grows by about the size of the SDK's native library (roughly 9 MB per CPU build). Krisp is left out.
- PKCE is not needed: Discord only requires it for custom-scheme deep links, and this flow redirects to the cloud worker over https.

## Worth knowing

On Android, Discord says presence can also be shown **without linking** when the Discord app is installed and signed in on the same
phone. A later option for phones; the link flow stays because it also works on TVs, which have no Discord app.
