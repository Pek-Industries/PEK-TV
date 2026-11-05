# Cloud endpoints the app calls

The server side (Cloudflare workers) is run by PEK Industries. It is proprietary and is not part of this repository.

## Hosts

| Host | Used for | Defined in |
|---|---|---|
| `https://api.pekindustries.com` | Accounts, sync, news, plugin backup, Discord link, subtitles | `cloud.dart` (`api`), `backend/subtitles.h` |
| `https://plugins.pekindustries.com` | The plugin store (`.PEK` files) | `plugin_store.dart` (`pluginBase`) |
| `https://store.pekindustries.com` | Skins (older store worker) | `plugin_store.dart` (`base`) |
| `https://tmdb.pekindustries.com` | TMDb proxy that holds the API key | `cloud.dart`, `recs.dart`, `backend/server.cpp` |
| `https://pekindustries.com/pektv` | The website (account page) | `cloud.dart` (`siteUrl`) |

## `/v1/...` routes, by caller

- **Account and sync** (`cloud.dart`): `auth/login`, `auth/logout`, `auth/confirm`, `auth/verify`, `auth/resend`, `auth/forgot`, `auth/reset`, `me`, `account`, `sync`, `profiles/sync`, `device/start`, `device/poll`
- **Discord link** (`cloud.dart`, `discord.dart`): `discord/start`, `discord/poll`, `discord/refresh`, `discord/revoke`
- **Plugin backup** (`plugin_backup.dart`): `plugins`, `plugins/chunk`, `plugins/commit`, `plugins/delete`
- **Plugin and skin stores** (`plugin_store.dart`): `plugins`, `app/plugins/`, `store`, `store/chunk`
- **News** (`news.dart`): `news`, `news/post`
- **Subtitles** (`backend/subtitles.h`): `subs/search`, `subs/get`
- **Weather** (`weather.dart`): `forecast`, `search`
- **Trailers** (`backend/trailer.h`): `player`

When you change one of these on the server, update the app (or this page) in the same step.
