import { CLOCK_SLACK, json, MAX_BODY, MAX_DATA, MAX_ITEMS, MAX_KEY, MAX_PASSWORD, MAX_PROFILE_ROWS, MAX_PROFILES, MAX_PUSH, PAGE } from './config.js';
import { checkPassword } from './crypto.js';
import { clearLimit, limited, readJson } from './input.js';

// ---------------------------------------------------------------- sync handlers
export function cleanItem(it, now, kind) {
    if (!it || typeof it !== 'object') return null;
    if (typeof it.key !== 'string' || !it.key || it.key.length > MAX_KEY) return null;
    // history keys start m| / e| (movie / episode), favorites are f|movie:<id> or f|tv:<id>,
    // settings are s|dashboard, s|look, s|weather or s|skin (small choices that follow the profile),
    // skins are k|<skin id>: k|custom-... (made in the app's Skin maker) or k|pkg-... (installed from a .zip / GitHub),
    // ratings are r|<history key> (r|m|<title>|<year> movie, r|e|<show>|<season>|<episode> episode, r|s|<show> whole show): 1 to 10 stars, per profile
    if (kind === 'f' ? !/^f\|(movie|tv):\d{1,10}$/.test(it.key)
        : kind === 's' ? !/^s\|(dashboard|look|weather|skin)$/.test(it.key)
        : kind === 'k' ? !/^k\|(custom-[a-z0-9]{1,20}|pkg-[a-z0-9][a-z0-9_-]{0,39})$/.test(it.key)
        : kind === 'r' ? !/^r\|[mes]\|.{1,150}$/.test(it.key)
        : !/^[me]\|/.test(it.key)) return null;
    const updated = Number(it.updated);
    if (!Number.isFinite(updated) || updated <= 0) return null;
    const deleted = it.deleted ? 1 : 0;
    // data {title, year, season, episode, rating 1..10, at}
    if (kind === 'r' && !deleted) {
        const d = it.data;
        if (!d || typeof d !== 'object' || !Number.isInteger(d.rating) || d.rating < 1 || d.rating > 10) return null;
    }
    const data = deleted ? '{}' : JSON.stringify(it.data && typeof it.data === 'object' ? it.data : {});
    if (data.length > MAX_DATA) return null;
    return { key: it.key, data, updated: Math.min(Math.floor(updated), now + CLOCK_SLACK), deleted };
}

// ---------------------------------------------------------------- profiles
// One account (email + password) for the household; each person in it is a profile with their own
// history, resume points and favorites. A profile's items live in the items table under
//   acct = <user id>                 for the profile called "p1" (the original one: accounts made before profiles
//                                    existed keep all of their data there, nothing is migrated)
//   acct = <user id>:<profile id>    for every other profile
// so every existing query keeps working, one namespace at a time. Plugin backups stay per account.
export function goodProfileId(id) { return typeof id === 'string' && /^[A-Za-z0-9_-]{1,32}$/.test(id); }
export function itemsAcct(userId, profile) { return (!profile || profile === 'p1') ? userId : userId + ':' + profile; }
export function likeProfiles(userId) { return userId + ':%'; }   // user ids are hex: no wildcard characters

// A profile picture is a built-in avatar id ("b:cat") or a small JPEG photo ("d:data:image/jpeg;base64,..."). The passcode is only ever a
// salted hash made on the device ("<16 hex>:<64 hex>"), never the digits.
export function goodAvatar(a) {
    if (a === '') return true;
    if (typeof a !== 'string' || a.length > 14000) return false;
    return /^b:[a-z]{2,16}$/.test(a) || /^d:data:image\/jpeg;base64,[A-Za-z0-9+\/=]+$/.test(a);
}
export function goodPin(p) { return p === '' || (typeof p === 'string' && /^[0-9a-f]{16}:[0-9a-f]{64}$/.test(p)); }

// POST /v1/auth/confirm  { password } -> { ok }   (session required)
// Lets the app re-check the account password, e.g. so a forgotten profile passcode can be removed. Shares the login
// failure limit, so it cannot be used to guess the password.
export async function handleConfirm(request, env, userId) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const password = typeof body.password === 'string' ? body.password.slice(0, MAX_PASSWORD) : '';
    if (!password) return json({ error: 'bad_credentials' }, 401);
    const key = 'confirm:' + userId;
    const lim = await db.prepare('SELECT n, reset_at FROM throttle WHERE k = ?').bind(key).first();
    if (lim && lim.reset_at > now && lim.n >= 6) return json({ error: 'rate_limited' }, 429);
    const row = await db.prepare('SELECT pw FROM users WHERE id = ?').bind(userId).first();
    const ok = row ? await checkPassword(password, row.pw) : false;
    if (!ok) { await limited(db, key, 6, 15 * 60 * 1000, now); return json({ error: 'bad_credentials' }, 401); }
    await clearLimit(db, key);
    return json({ ok: true });
}

// POST /v1/profiles/sync  { profiles: [{ id, name, color, updated, deleted, avatar, pin }] } -> { ok, profiles, rejected }
// Last writer wins per profile, by its own "updated" time. Removing a profile (deleted: 1) also removes its stored items.
export async function handleProfiles(request, env, userId) {
    const text = await request.text();
    if (text.length > 160 * 1024) return json({ error: 'too_large' }, 413);   // up to 5 small photos
    let body;
    try { body = JSON.parse(text); } catch (e) { return json({ error: 'bad_json' }, 400); }
    const incoming = body && Array.isArray(body.profiles) ? body.profiles.slice(0, 40) : null;
    if (!incoming) return json({ error: 'bad_json' }, 400);

    const db = env.DB;
    const now = Date.now();
    const rows = (await db.prepare('SELECT id, name, color, updated, deleted, avatar, pin FROM profiles WHERE acct = ?').bind(userId).all()).results || [];
    const have = {};
    rows.forEach(r => { have[r.id] = { id: r.id, name: r.name, color: r.color, updated: r.updated, deleted: r.deleted ? 1 : 0, avatar: r.avatar || '', pin: r.pin || '' }; });
    let live = rows.filter(r => !r.deleted).length;
    let total = rows.length;
    const stmts = [];
    const rejected = [];

    for (const raw of incoming) {
        if (!raw || typeof raw !== 'object' || !goodProfileId(raw.id)) continue;
        const updated = Math.min(Math.floor(Number(raw.updated) || 0), now + CLOCK_SLACK);
        if (updated < 0) continue;
        const deleted = raw.deleted ? 1 : 0;
        const name = deleted ? '' : String(raw.name == null ? '' : raw.name).replace(/\s+/g, ' ').trim().slice(0, 40);
        const color = deleted ? '' : (/^#[0-9a-fA-F]{6}$/.test(raw.color) ? raw.color : '#E04A00');
        if (!deleted && !name) continue;
        const avatar = deleted ? '' : goodAvatar(raw.avatar) ? raw.avatar : '';
        const pin = deleted ? '' : goodPin(raw.pin) ? raw.pin : '';
        const cur = have[raw.id];
        if (cur && updated <= cur.updated) continue;                       // the cloud's copy is as new or newer
        if (!cur && !deleted && live >= MAX_PROFILES) { rejected.push(raw.id); continue; }
        if (!cur && total >= MAX_PROFILE_ROWS) { rejected.push(raw.id); continue; }
        if (deleted && cur && !cur.deleted && live <= 1) { rejected.push(raw.id); continue; }   // never remove the last one
        if (deleted && !cur) continue;                                      // nothing to remove, nothing to remember
        if (!cur) total++;
        if (!cur || cur.deleted) { if (!deleted) live++; }
        else if (deleted) live--;
        have[raw.id] = { id: raw.id, name, color, updated, deleted, avatar, pin };
        stmts.push(db.prepare(
            'INSERT INTO profiles (acct, id, name, color, updated, deleted, avatar, pin) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ' +
            'ON CONFLICT(acct, id) DO UPDATE SET name = excluded.name, color = excluded.color, updated = excluded.updated, deleted = excluded.deleted, avatar = excluded.avatar, pin = excluded.pin'
        ).bind(userId, raw.id, name, color, updated, deleted, avatar, pin));
        if (deleted) stmts.push(db.prepare('DELETE FROM items WHERE acct = ?').bind(itemsAcct(userId, raw.id)));
    }
    if (stmts.length) await db.batch(stmts);
    await db.prepare('UPDATE users SET last_seen = ? WHERE id = ?').bind(now, userId).run();
    const out = Object.keys(have).map(k => have[k]).sort((a, b) => a.updated - b.updated || (a.id < b.id ? -1 : 1));
    return json({ ok: true, profiles: out, rejected });
}

export async function handleSync(request, env, userId) {
    const text = await request.text();
    if (text.length > MAX_BODY) return json({ error: 'too_large' }, 413);
    let body;
    try { body = JSON.parse(text); } catch (e) { return json({ error: 'bad_json' }, 400); }
    if (!body || typeof body !== 'object') return json({ error: 'bad_json' }, 400);

    const db = env.DB;
    const now = Date.now();
    await db.prepare('UPDATE users SET last_seen = ? WHERE id = ?').bind(now, userId).run();

    // Which profile's data this is. No profile (an older app) means the original one, "p1".
    const profile = body.profile == null ? 'p1' : body.profile;
    if (!goodProfileId(profile)) return json({ error: 'bad_profile' }, 400);
    if (profile !== 'p1') {   // other profiles must have been announced through /v1/profiles/sync and not removed
        const pr = await db.prepare('SELECT deleted FROM profiles WHERE acct = ? AND id = ?').bind(userId, profile).first();
        if (!pr || pr.deleted) return json({ error: 'unknown_profile' }, 404);
    }
    const acct = itemsAcct(userId, profile);

    // ---- push: last writer wins per item, by the item's own "updated" time
    const pushed = [];
    for (const [kind, field] of [['h', 'history'], ['p', 'progress'], ['f', 'favorites'], ['s', 'settings'], ['k', 'skins'], ['r', 'ratings']]) {
        const list = Array.isArray(body[field]) ? body[field] : [];
        for (const raw of list) pushed.push([kind, raw]);
    }
    if (pushed.length > MAX_PUSH) return json({ error: 'too_many_items' }, 413);

    if (pushed.length) {
        const countRow = await db.prepare('SELECT COUNT(*) AS n FROM items WHERE acct = ?').bind(acct).first();
        let total = countRow ? countRow.n : 0;
        const stmts = [];
        let i = 0;
        for (const [kind, raw] of pushed) {
            const it = cleanItem(raw, now, kind);
            if (!it) continue;
            if (total >= MAX_ITEMS) break;
            total++;
            stmts.push(db.prepare(
                'INSERT INTO items (acct, kind, key, data, updated, deleted, srv) VALUES (?, ?, ?, ?, ?, ?, ?) ' +
                'ON CONFLICT(acct, kind, key) DO UPDATE SET data = excluded.data, updated = excluded.updated, ' +
                'deleted = excluded.deleted, srv = excluded.srv WHERE excluded.updated > items.updated'
            ).bind(acct, kind, it.key, it.data, it.updated, it.deleted, now * 1000 + (i++)));
        }
        if (stmts.length) await db.batch(stmts);
    }

    // ---- pull: everything stored at or after the client's cursor
    const since = Math.max(0, Number(body.since) || 0);
    const rows = await db.prepare(
        'SELECT kind, key, data, updated, deleted, srv FROM items WHERE acct = ? AND srv >= ? ORDER BY srv, kind, key LIMIT ?'
    ).bind(acct, since, PAGE).all();
    const results = rows.results || [];

    const out = { history: [], progress: [], favorites: [], settings: [], skins: [], ratings: [] };
    let cursor = since;
    for (const r of results) {
        let data = {};
        try { data = JSON.parse(r.data); } catch (e) { /* keep {} */ }
        const item = { key: r.key, data, updated: r.updated, deleted: r.deleted ? 1 : 0 };
        (r.kind === 'h' ? out.history : r.kind === 'f' ? out.favorites : r.kind === 's' ? out.settings : r.kind === 'k' ? out.skins : r.kind === 'r' ? out.ratings : out.progress).push(item);
        if (r.srv > cursor) cursor = r.srv;
    }
    return json({ ok: true, profile, cursor, more: results.length === PAGE, history: out.history, progress: out.progress, favorites: out.favorites, settings: out.settings, skins: out.skins, ratings: out.ratings });
}
