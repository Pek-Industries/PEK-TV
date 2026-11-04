// ---------------------------------------------------------------- database
let ready = false;
export async function init(db) {
    if (ready) return;
    // one at a time: an index can only be created once its table exists
    await db.prepare('CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, pw TEXT NOT NULL, created INTEGER NOT NULL, last_seen INTEGER NOT NULL, verified INTEGER NOT NULL DEFAULT 0)').run();
    // A users table made before email verification existed has no such column: add it (those accounts count as verified).
    try { await db.prepare('ALTER TABLE users ADD COLUMN verified INTEGER NOT NULL DEFAULT 1').run(); } catch (e) { /* already there */ }
    // gf = 1: the account existed before invite-only sign-up, so it is never asked for a code. New sign-ups are stored with gf = 0.
    try { await db.prepare('ALTER TABLE users ADD COLUMN gf INTEGER NOT NULL DEFAULT 1').run(); } catch (e) { /* already there */ }
    // Username (3 to 20 characters, required at sign-up), unique ignoring upper/lower case. Older accounts have none ('').
    try { await db.prepare("ALTER TABLE users ADD COLUMN username TEXT NOT NULL DEFAULT ''").run(); } catch (e) { /* already there */ }
    // Plans. Rows that already exist when these columns are added get 'grandfathered' (the column default); sign-up stores 'free'.
    try { await db.prepare("ALTER TABLE users ADD COLUMN plan TEXT NOT NULL DEFAULT 'grandfathered'").run(); } catch (e) { /* already there */ }
    try { await db.prepare('ALTER TABLE users ADD COLUMN plan_until INTEGER NOT NULL DEFAULT 0').run(); } catch (e) { /* already there */ }
    try { await db.prepare('ALTER TABLE users ADD COLUMN plan_cancel INTEGER NOT NULL DEFAULT 0').run(); } catch (e) { /* already there */ }
    try { await db.prepare("ALTER TABLE users ADD COLUMN stripe_customer TEXT NOT NULL DEFAULT ''").run(); } catch (e) { /* already there */ }
    try { await db.prepare("ALTER TABLE users ADD COLUMN stripe_sub TEXT NOT NULL DEFAULT ''").run(); } catch (e) { /* already there */ }
    // When the current paid plan started (ms), the moment an unpaid account is deleted (ms, 0 = not scheduled), and which deletion email was sent last.
    try { await db.prepare('ALTER TABLE users ADD COLUMN plan_since INTEGER NOT NULL DEFAULT 0').run(); } catch (e) { /* already there */ }
    try { await db.prepare('ALTER TABLE users ADD COLUMN delete_at INTEGER NOT NULL DEFAULT 0').run(); } catch (e) { /* already there */ }
    try { await db.prepare('ALTER TABLE users ADD COLUMN notice_stage INTEGER NOT NULL DEFAULT 0').run(); } catch (e) { /* already there */ }
    // When the last "your payment is overdue" email (grace period) was sent (ms): the daily job sends one per day while the grace lasts.
    try { await db.prepare('ALTER TABLE users ADD COLUMN grace_mail_at INTEGER NOT NULL DEFAULT 0').run(); } catch (e) { /* already there */ }
    // When the last deletion-countdown email was sent (ms): the daily job sends one every NOTICE_EVERY_MS until the account is deleted.
    try { await db.prepare('ALTER TABLE users ADD COLUMN notice_at INTEGER NOT NULL DEFAULT 0').run(); } catch (e) { /* already there */ }
    // Sessions of accounts the daily job deleted: so the app and the website can say "your account was deleted" instead of just "sign in again".
    await db.prepare('CREATE TABLE IF NOT EXISTS gone_sessions (token_hash TEXT PRIMARY KEY, deleted INTEGER NOT NULL)').run();
    await db.prepare("CREATE UNIQUE INDEX IF NOT EXISTS users_username ON users (username COLLATE NOCASE) WHERE username <> ''").run();
    await db.prepare('CREATE TABLE IF NOT EXISTS invites (hash TEXT PRIMARY KEY, created INTEGER NOT NULL, expires INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT \'\', reserved_by TEXT, reserved_until INTEGER NOT NULL DEFAULT 0, used_by TEXT, used_at INTEGER)').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS verifs (user_id TEXT PRIMARY KEY, code_hash TEXT NOT NULL, expires INTEGER NOT NULL, tries INTEGER NOT NULL DEFAULT 0)').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL)').run();
    await db.prepare('CREATE INDEX IF NOT EXISTS sessions_user ON sessions (user_id)').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS resets (user_id TEXT PRIMARY KEY, code_hash TEXT NOT NULL, expires INTEGER NOT NULL, tries INTEGER NOT NULL DEFAULT 0)').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS throttle (k TEXT PRIMARY KEY, n INTEGER NOT NULL, reset_at INTEGER NOT NULL)').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS items (acct TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, data TEXT NOT NULL, updated INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, srv INTEGER NOT NULL, PRIMARY KEY (acct, kind, key))').run();
    await db.prepare('CREATE INDEX IF NOT EXISTS items_srv ON items (acct, srv)').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS profiles (acct TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL, updated INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (acct, id))').run();
    // Profile picture and passcode hash (added later: older tables get the columns here).
    try { await db.prepare("ALTER TABLE profiles ADD COLUMN avatar TEXT NOT NULL DEFAULT ''").run(); } catch (e) { /* already there */ }
    try { await db.prepare("ALTER TABLE profiles ADD COLUMN pin TEXT NOT NULL DEFAULT ''").run(); } catch (e) { /* already there */ }
    await db.prepare('CREATE TABLE IF NOT EXISTS plugins (acct TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL, size INTEGER NOT NULL, fp TEXT NOT NULL, chunks INTEGER NOT NULL, updated INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (acct, id))').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS plugin_chunks (acct TEXT NOT NULL, id TEXT NOT NULL, fp TEXT NOT NULL, idx INTEGER NOT NULL, data TEXT NOT NULL, created INTEGER NOT NULL, PRIMARY KEY (acct, id, fp, idx))').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS store_plugins (id TEXT PRIMARY KEY, shelf TEXT NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL, author TEXT NOT NULL DEFAULT \'\', description TEXT NOT NULL DEFAULT \'\', size INTEGER NOT NULL, fp TEXT NOT NULL, chunks INTEGER NOT NULL, status TEXT NOT NULL, owner TEXT NOT NULL, updated INTEGER NOT NULL)').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS store_chunks (owner TEXT NOT NULL, id TEXT NOT NULL, fp TEXT NOT NULL, idx INTEGER NOT NULL, data TEXT NOT NULL, created INTEGER NOT NULL, PRIMARY KEY (owner, id, fp, idx))').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS gh_states (state TEXT PRIMARY KEY, ret TEXT NOT NULL, created INTEGER NOT NULL)').run();
    await db.prepare('CREATE TABLE IF NOT EXISTS gh_sessions (token_hash TEXT PRIMARY KEY, gh_id TEXT NOT NULL, login TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL)').run();
    // TV link login: a TV asks for a 6-digit code, the person approves it on the website, the TV collects a session.
    await db.prepare('CREATE TABLE IF NOT EXISTS device_links (poll_hash TEXT PRIMARY KEY, code_hash TEXT NOT NULL, dtype TEXT NOT NULL, dname TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL, user_id TEXT)').run();
    await db.prepare('CREATE UNIQUE INDEX IF NOT EXISTS device_links_code ON device_links (code_hash)').run();
    // Discord link (Rich Presence): a TV or phone starts a link, the person approves PEK TV in Discord, the app collects the tokens once.
    await db.prepare("CREATE TABLE IF NOT EXISTS discord_links (poll_hash TEXT PRIMARY KEY, state TEXT NOT NULL UNIQUE, created INTEGER NOT NULL, expires INTEGER NOT NULL, access TEXT, refresh TEXT, expires_in INTEGER NOT NULL DEFAULT 0, scope TEXT NOT NULL DEFAULT '')").run();
    // Where the TV asked for its code (its IP address and the approximate place that IP is in), shown to the person who approves.
    try { await db.prepare("ALTER TABLE device_links ADD COLUMN ip TEXT NOT NULL DEFAULT ''").run(); } catch (e) { /* already there */ }
    try { await db.prepare("ALTER TABLE device_links ADD COLUMN loc TEXT NOT NULL DEFAULT ''").run(); } catch (e) { /* already there */ }
    // Which TV-link a session came from, so rejecting that login can sign that one device out again.
    try { await db.prepare('ALTER TABLE sessions ADD COLUMN dev_ref TEXT').run(); } catch (e) { /* already there */ }
    // One-time links in emails: "Wasn't you? Reject this login". Only the hash of the token is stored.
    await db.prepare('CREATE TABLE IF NOT EXISTS reject_tokens (hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, kind TEXT NOT NULL, ref TEXT NOT NULL DEFAULT \'\', created INTEGER NOT NULL, expires INTEGER NOT NULL)').run();
    // The app's Updates screen: messages you post (news, new coupon codes). Anyone can read them, only the ADMIN_KEY can post.
    await db.prepare("CREATE TABLE IF NOT EXISTS announcements (id INTEGER PRIMARY KEY AUTOINCREMENT, created INTEGER NOT NULL, expires INTEGER NOT NULL DEFAULT 0, kind TEXT NOT NULL DEFAULT 'news', title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', code TEXT NOT NULL DEFAULT '', link TEXT NOT NULL DEFAULT '')").run();
    await db.prepare('CREATE TABLE IF NOT EXISTS subs_cache (id TEXT PRIMARY KEY, text TEXT NOT NULL, created INTEGER NOT NULL)').run();
    ready = true;
}
