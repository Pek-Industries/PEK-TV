# pek-sync, split into modules

Same worker, same routes, same behaviour. `worker.js` (2,000 lines) is now `src/*.js`.

| File | What is in it |
|---|---|
| index.js | route list (header) + the router (`fetch`, `scheduled`) |
| config.js | limits, TTLs, CORS, `json()` |
| db.js | `init()` and the D1 schema |
| crypto.js, input.js | hashing/tokens, input checks, rate limiting |
| invites.js, admin.js | invite codes; admin endpoints (ADMIN_KEY) |
| sessions.js, auth.js, device.js | sessions; sign-up/in/reset; TV link login |
| mail.js | Brevo emails |
| account.js | plans, /v1/me, username, export, delete |
| sync.js, plugin-backup.js | profiles + sync; plugin backups |
| store.js | GitHub sign-in + Plugin Store |
| subtitles.js, news.js, discord.js | those features |
| lifecycle.js | the daily cron job for lapsed plans |

Deploy from Termux (use this instead of deploy-worker.sh):

    sh deploy-modules.sh src pek-sync

With wrangler, set `"main": "src/index.js"` and it bundles the imports for you.
Nothing about the worker's name, bindings, secrets, cron or URL changes.
