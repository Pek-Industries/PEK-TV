# PEK Plugin Store: set it up on Cloudflare (phone friendly)

What you are building:

| Piece | What it does | Where it lives |
|---|---|---|
| Website pages (`store.html`, `store-plugin.html`, `store-upload.html`, `store-mine.html`, `store-owner.html`) | Browse, look at a plugin, upload, review | Your existing Pages project `pek-tv` |
| `pek-plugins` Worker | The brains: checks every upload, stores plugins, gates downloads | New Worker |
| R2 bucket `pek-plugins-files` | Holds the `.PEK` files and screenshots | New |
| D1 database `pek-plugins` | Names, versions, status, counters | New |
| `pek-sync` Worker | Your PEK accounts (already exists, not changed) | Existing |
| `pek-store` Worker | Still serves **skins** only (skins are not .PEK) | Existing, left alone |

Rules it enforces: browsing is public. Downloading a `.PEK` **from the website** needs a PEK account. Uploading needs a GitHub sign-in. The **app** downloads without an account. Only `.PEK` files are accepted; a `.zip` (even renamed) is rejected.

Use Chrome menu (three dots) -> **Desktop site** for the Cloudflare dashboard.

---

## Step 1. R2 bucket (stores the files)
1. Dashboard -> **Storage & databases -> R2 object storage -> Create bucket**.
2. Name: `pek-plugins-files`. Location: Automatic. Create.
   R2 asks for a payment method once; the free allowance (10 GB, no download fees) is far more than you need.
3. Leave it private. Do **not** turn on public access: the Worker is the only door, which is how the account rule works.

## Step 2. D1 database
1. **Storage & databases -> D1 SQL database -> Create** -> name `pek-plugins`.
2. Nothing else. The Worker creates its own tables the first time it runs.

## Step 3. The Worker
1. **Workers & Pages -> Create -> Worker** (Hello World) -> name exactly `pek-plugins` -> Deploy -> **Edit code**.
2. Select all, delete, paste the whole of `pek-plugins-worker/worker.js` -> **Deploy**.
3. **Settings -> Bindings -> Add**:
   - **D1 database** -> variable name `DB` (exactly) -> `pek-plugins`.
   - **R2 bucket** -> variable name `PLUGINS` (exactly) -> `pek-plugins-files`.
   Deploy again if asked.
4. Open `https://plugins.pekindustries.com/v1/plugins`. You should see `{"ok":true,"items":[]}`. (If you see `no_database_bound` or `no_r2_bucket_bound`, a binding name is wrong.)

If you name the Worker something else, change `API` at the top of `public/pektv/js/store.js` and `pluginBase` in `flutter_ui/lib/src/plugin_store.dart`.

## Step 4. GitHub sign-in for uploads
1. GitHub -> Settings -> Developer settings -> **OAuth Apps -> New OAuth App** (make a new one; the old store's app has a different callback).
   - Application name: `PEK Plugin Store`
   - Homepage URL: `https://pekindustries.com/pektv/store`
   - Authorization callback URL: `https://plugins.pekindustries.com/v1/gh/callback`
2. Register, then **Generate a new client secret**. Copy the Client ID and the secret.
3. Worker `pek-plugins` -> **Settings -> Variables and Secrets -> Add**:

| Name | Type | Value |
|---|---|---|
| `GITHUB_CLIENT_ID` | Text | the Client ID |
| `GITHUB_CLIENT_SECRET` | **Secret** | the client secret |
| `SITE_URL` | Text | `https://pekindustries.com/pektv/` (keep the trailing `/`) |
| `OWNER_GITHUB` | Text | your GitHub username (several: comma separated) |
| `MIN_ACCOUNT_DAYS` | Text, optional | `7` = GitHub accounts younger than this cannot upload |
| `BLOCKED_GITHUB` | Text, optional | usernames to refuse |
| `PEK_ACCOUNT_API` | Text, optional | only if your accounts worker is not `https://pek-sync.aquariusibeats.workers.dev` |

4. Deploy.

## Step 5. Put the website pages live
1. Use `upload-to-cloudflare.zip` (it is the **contents** of `public/`).
2. **Workers & Pages -> pek-tv -> Deployments -> Create new deployment** -> upload the zip -> Deploy.
3. Check: `https://pekindustries.com/pektv/store` loads and says there is nothing yet. A "Store" link is now in the menu of every page.
4. If the plugin pages can't reach the Worker, open the browser console: a CORS error means the site's address isn't allowed. The Worker allows `pekindustries.com`, `www.pekindustries.com`, `pek-tv.pages.dev`, `pek-tv.web.app`, any `*.aquariusibeats.workers.dev`, and the host of `SITE_URL`.

## Step 6. Publish your official plugins (so the app can update the built-ins)
1. Go to `https://pekindustries.com/pektv/store-owner` -> **Sign in with GitHub** (the account in `OWNER_GITHUB`).
2. **Publish an official plugin** -> pick `plugin_packages/weather.PEK` -> shelf **Official** -> tick the box -> Upload. Repeat for `tmdb-discover.PEK` and `skin-maker.PEK`.
   Owner uploads on the Official shelf go live immediately and may use the built-in ids and the reserved TMDb host. Nobody else can.
3. Open `/pektv/store`: they are listed with icons.

## Step 7. Build the app
Copy `flutter_ui/lib/src/plugin_store.dart` from `pektv-changes` over yours and build as usual. The app now lists plugins from the new Worker with `inline_icons=1`, downloads the `.PEK`, checks its SHA-256 against the listing, then runs the same full `.PEK` reader and install screens as before. Skins still use `pek-store`.

## How a community upload works
1. Someone opens **Upload a plugin**, signs in with GitHub, picks a `.PEK`. The page checks it in the browser and shows exactly what the store will show (icon, permissions in plain words, problems in red). They add a description and up to 6 screenshots (PNG/JPG/WebP, 2 MB each).
2. The Worker re-checks everything itself (signature, checksums, size caps, rules, real image types). Upload lands as **Waiting for review**.
3. You open `/pektv/store-owner` -> **Review** (permissions, files, screenshots) -> **Download .PEK** and read `screen.py` / `backend.py` -> **Approve** or **Reject** (with a note the uploader sees under *My uploads*).
4. Approved plugins appear on the Community shelf and in the app. An update (same id) goes back to *Waiting for review* until approved again.

## Things to know
- **Website vs app download** are two different Worker routes (`/v1/plugins/<id>/download` needs a PEK account, `/v1/app/plugins/<id>/download` doesn't). Someone who reads the app's address can use the app route by hand. It is rate limited (120 an hour per IP) but it is not secret; that is the price of "no account in the app".
- Downloads from the website are rate limited to 100 an hour per account.
- Screenshots can only be changed by uploading the `.PEK` again (so approved plugins can't have pictures swapped afterwards). Leave the screenshots empty on an update to keep the old ones.
- The `with the icon` part: the plugin's own icon (the `icon` in `plugin.json`) is shown on every card and page, and the upload form tells people to include it in their screenshots.
- To remove something: owner page -> Remove. Uploaders can remove their own under *My uploads*.
- Skins are still `.zip` through the old `pek-store` Worker. They are not `.PEK`, so they are outside this change.
- Make a `.PEK` yourself: `python tools/pektool.py pack ./my-plugin --clean`. Official built-ins need `python tools/pektool.py --official pack plugins/weather --clean -o plugin_packages/weather.PEK`.
- If you change the `.PEK` format, change it in `tools/pektool.py`, `plugin_pek.dart` and `pek-core.js` (the Worker and the website share that one file).
- Old zips are in `plugin_packages/(legacy)/`; nothing reads them.
