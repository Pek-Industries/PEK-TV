import { json, MAX_PLUGIN_CHUNKS, MAX_PLUGIN_RAW, PLUGIN_CHUNK } from './config.js';
import { randomHex, randomToken, sha256Hex } from './crypto.js';
import { clientIp, limited, readJson } from './input.js';
import { goodFp, goodPluginId, shortText } from './plugin-backup.js';

// ---------------------------------------------------------------- GitHub sign-in + Plugin Store
// One store, two shelves, both browsable and downloadable WITHOUT any sign-in:
//   official   plugins published by the owner(s). Live immediately.
//   community  everyone else's. Uploaded from the GitHub Pages site, hidden until an owner approves.
// Everyone who uploads signs in with GitHub (mandatory). Owners are the GitHub accounts listed in OWNER_GITHUB.
//
// Worker settings (Variables and Secrets):
//   GITHUB_CLIENT_ID      (Text)    from your GitHub OAuth App
//   GITHUB_CLIENT_SECRET  (Secret)  from your GitHub OAuth App
//   SITE_URL              (Text)    the address of your GitHub Pages site, e.g. https://you.github.io/pek-plugins/
//   OWNER_GITHUB          (Text)    your GitHub username(s), comma separated
//   MIN_ACCOUNT_DAYS      (Text, optional)  newest GitHub account allowed to upload, default 7
//   BLOCKED_GITHUB        (Text, optional)  usernames (or numeric ids) refused at sign-in, comma separated
export const GH_SESSION_TTL = 7 * 24 * 3600 * 1000;
export const GH_STATE_TTL = 10 * 60 * 1000;
export const STORE_MAX_PER_USER = 10;         // community plugins one GitHub account may have (pending + approved)
export const STORE_MAX_SIZE = MAX_PLUGIN_RAW;

export function csv(v) { return String(v || '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean); }
export function inList(list, gh) { return list.indexOf(String(gh.login).toLowerCase()) >= 0 || list.indexOf(String(gh.id)) >= 0; }
export function siteUrl(env) { const u = String(env.SITE_URL || ''); return /^https:\/\//.test(u) ? (u.endsWith('/') ? u : u + '/') : ''; }

export function siteRedirect(env, page, hash) {
    const base = siteUrl(env);
    if (!base) return json({ error: 'site_not_configured' }, 500);
    return new Response(null, { status: 302, headers: { Location: base + (page === 'owner' ? 'owner.html' : '') + '#' + hash, 'Cache-Control': 'no-store' } });
}

export async function ghLogin(url, request, env) {
    if (!env.GITHUB_CLIENT_ID || !env.GITHUB_CLIENT_SECRET || !siteUrl(env)) return json({ error: 'github_not_configured' }, 500);
    const now = Date.now();
    if (await limited(env.DB, 'gh:login:' + clientIp(request), 30, 10 * 60 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    const ret = url.searchParams.get('ret') === 'owner' ? 'owner' : 'upload';
    const state = randomHex(16);
    await env.DB.batch([
        env.DB.prepare('DELETE FROM gh_states WHERE created < ?').bind(now - GH_STATE_TTL),
        env.DB.prepare('INSERT INTO gh_states (state, ret, created) VALUES (?, ?, ?)').bind(state, ret, now)
    ]);
    const to = 'https://github.com/login/oauth/authorize?client_id=' + encodeURIComponent(env.GITHUB_CLIENT_ID) +
        '&redirect_uri=' + encodeURIComponent(url.origin + '/v1/gh/callback') + '&state=' + state + '&allow_signup=true';
    return new Response(null, { status: 302, headers: { Location: to, 'Cache-Control': 'no-store' } });
}

export async function ghCallback(url, env) {
    const now = Date.now();
    const state = url.searchParams.get('state') || '', code = url.searchParams.get('code') || '';
    const row = /^[a-f0-9]{32}$/.test(state)
        ? await env.DB.prepare('SELECT ret, created FROM gh_states WHERE state = ?').bind(state).first() : null;
    if (row) await env.DB.prepare('DELETE FROM gh_states WHERE state = ?').bind(state).run();   // one use only
    if (!row || row.created < now - GH_STATE_TTL) return siteRedirect(env, 'upload', 'error=expired');
    const page = row.ret;
    if (!code) return siteRedirect(env, page, 'error=denied');

    let access = '', gh = null;
    try {
        const t = await fetch('https://github.com/login/oauth/access_token', {
            method: 'POST',
            headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'User-Agent': 'pek-store' },
            body: JSON.stringify({ client_id: env.GITHUB_CLIENT_ID, client_secret: env.GITHUB_CLIENT_SECRET, code })
        });
        access = ((await t.json()) || {}).access_token || '';
        if (access) {
            const u = await fetch('https://api.github.com/user', { headers: { 'Authorization': 'Bearer ' + access, 'Accept': 'application/vnd.github+json', 'User-Agent': 'pek-store' } });
            if (u.ok) gh = await u.json();
        }
    } catch (e) { /* handled below */ }
    // We only needed to learn who this is; revoke GitHub's token straight away (best effort).
    if (access) {
        try {
            await fetch('https://api.github.com/applications/' + encodeURIComponent(env.GITHUB_CLIENT_ID) + '/token', {
                method: 'DELETE',
                headers: { 'Authorization': 'Basic ' + btoa(env.GITHUB_CLIENT_ID + ':' + env.GITHUB_CLIENT_SECRET), 'Accept': 'application/vnd.github+json', 'User-Agent': 'pek-store', 'Content-Type': 'application/json' },
                body: JSON.stringify({ access_token: access })
            });
        } catch (e) { /* not important */ }
    }
    if (!gh || !gh.id || !gh.login) return siteRedirect(env, page, 'error=github');
    if (inList(csv(env.BLOCKED_GITHUB), gh)) return siteRedirect(env, page, 'error=blocked');
    const owner = inList(csv(env.OWNER_GITHUB), gh);
    const minDays = Number(env.MIN_ACCOUNT_DAYS == null || env.MIN_ACCOUNT_DAYS === '' ? 7 : env.MIN_ACCOUNT_DAYS);
    const age = gh.created_at ? (now - Date.parse(gh.created_at)) / 86400000 : 0;
    if (!owner && Number.isFinite(minDays) && age < minDays) return siteRedirect(env, page, 'error=too_new');
    if (page === 'owner' && !owner) return siteRedirect(env, page, 'error=not_owner');

    const token = randomToken();
    await env.DB.batch([
        env.DB.prepare('DELETE FROM gh_sessions WHERE expires < ?').bind(now),
        env.DB.prepare('INSERT INTO gh_sessions (token_hash, gh_id, login, created, expires) VALUES (?, ?, ?, ?, ?)')
            .bind(await sha256Hex('hesper:gh:' + token), String(gh.id), String(gh.login), now, now + GH_SESSION_TTL)
    ]);
    return siteRedirect(env, page, 'token=' + encodeURIComponent(token));
}

// Who is calling? Reads the GitHub session token. Owner / blocked status is re-checked on every call,
// so removing a name from OWNER_GITHUB or adding one to BLOCKED_GITHUB takes effect straight away.
export async function ghSession(request, env, now) {
    const m = /^Bearer\s+(\S+)$/i.exec(request.headers.get('Authorization') || '');
    if (!m || m[1].length < 20 || m[1].length > 100) return null;
    const hash = await sha256Hex('hesper:gh:' + m[1]);
    const r = await env.DB.prepare('SELECT gh_id, login, expires FROM gh_sessions WHERE token_hash = ?').bind(hash).first();
    if (!r || r.expires < now) return null;
    const gh = { id: r.gh_id, login: r.login };
    if (inList(csv(env.BLOCKED_GITHUB), gh)) return null;
    return { id: 'gh:' + r.gh_id, login: r.login, owner: inList(csv(env.OWNER_GITHUB), gh), hash };
}

export function storeItem(r) {
    return { id: r.id, shelf: r.shelf, name: r.name, version: r.version, author: r.author, description: r.description,
             size: r.size, fp: r.fp, chunks: r.chunks, status: r.status, updated: r.updated };
}

export async function storeList(url, env) {
    const shelf = url.searchParams.get('shelf');
    const q = shelf === 'official' || shelf === 'community'
        ? env.DB.prepare("SELECT * FROM store_plugins WHERE status = 'approved' AND shelf = ? ORDER BY name").bind(shelf)
        : env.DB.prepare("SELECT * FROM store_plugins WHERE status = 'approved' ORDER BY shelf, name");
    const rows = await q.all();
    return json({ ok: true, items: (rows.results || []).map(storeItem) });
}

// Download one chunk. Public for approved items; owners may also read pending ones (to review them).
export async function storeGetChunk(url, env, allowPending) {
    const id = url.searchParams.get('id'), fp = url.searchParams.get('fp'), i = Number(url.searchParams.get('i'));
    if (!goodPluginId(id) || !goodFp(fp) || !Number.isInteger(i) || i < 0) return json({ error: 'bad_plugin' }, 400);
    const row = await env.DB.prepare('SELECT owner, status FROM store_plugins WHERE id = ? AND fp = ?').bind(id, fp).first();
    if (!row || (row.status !== 'approved' && !allowPending)) return json({ error: 'not_found' }, 404);
    const c = await env.DB.prepare('SELECT data FROM store_chunks WHERE owner = ? AND id = ? AND fp = ? AND idx = ?').bind(row.owner, id, fp, i).first();
    if (!c) return json({ error: 'not_found' }, 404);
    return json({ ok: true, data: c.data });
}

// Upload one chunk. Chunks are filed under their uploader, so nobody can overwrite another person's files.
export async function storePutChunk(request, env, who) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const index = Number(body.index), total = Number(body.total);
    if (!goodPluginId(body.id) || !goodFp(body.fp)) return json({ error: 'bad_plugin' }, 400);
    if (!Number.isInteger(index) || !Number.isInteger(total) || total < 1 || total > MAX_PLUGIN_CHUNKS || index < 0 || index >= total) return json({ error: 'bad_plugin' }, 400);
    if (typeof body.data !== 'string' || !body.data.length || body.data.length > PLUGIN_CHUNK + 1000) return json({ error: 'too_large' }, 413);
    if (!who.owner && await limited(db, 'store:chunk:' + who.id, 400, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    await db.prepare('INSERT INTO store_chunks (owner, id, fp, idx, data, created) VALUES (?, ?, ?, ?, ?, ?) ' +
        'ON CONFLICT(owner, id, fp, idx) DO UPDATE SET data = excluded.data, created = excluded.created')
        .bind(who.id, body.id, body.fp, index, body.data, now).run();
    return json({ ok: true });
}

// official = true only ever comes from the owner route.
export async function storeCommit(request, env, who, official) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const total = Number(body.total), size = Number(body.size);
    if (!goodPluginId(body.id) || !goodFp(body.fp)) return json({ error: 'bad_plugin' }, 400);
    if (!Number.isInteger(total) || total < 1 || total > MAX_PLUGIN_CHUNKS) return json({ error: 'bad_plugin' }, 400);
    if (!Number.isFinite(size) || size < 1 || size > STORE_MAX_SIZE) return json({ error: 'too_large' }, 413);
    const have = await db.prepare('SELECT COUNT(*) AS n FROM store_chunks WHERE owner = ? AND id = ? AND fp = ?').bind(who.id, body.id, body.fp).first();
    if (!have || have.n !== total) return json({ error: 'incomplete' }, 400);

    const cur = await db.prepare('SELECT owner, shelf FROM store_plugins WHERE id = ?').bind(body.id).first();
    if (!official) {
        if (cur && (cur.shelf === 'official' || cur.owner !== who.id)) return json({ error: 'id_taken' }, 409);
        const mine = await db.prepare("SELECT COUNT(*) AS n FROM store_plugins WHERE owner = ? AND shelf = 'community' AND id != ?").bind(who.id, body.id).first();
        if (mine && mine.n >= STORE_MAX_PER_USER) return json({ error: 'store_quota' }, 413);
        if (await limited(db, 'store:submit:' + who.id, 20, 24 * 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    }
    const shelf = official ? 'official' : 'community';
    const status = official ? 'approved' : 'pending';          // community uploads wait for an owner
    // On Community the author is always the signed-in GitHub account, whatever plugin.json says.
    const author = official ? (shortText(body.author, 80) || who.login) : who.login;
    await db.batch([
        db.prepare('INSERT INTO store_plugins (id, shelf, name, version, author, description, size, fp, chunks, status, owner, updated) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' +
            'ON CONFLICT(id) DO UPDATE SET shelf = excluded.shelf, name = excluded.name, version = excluded.version, author = excluded.author, ' +
            'description = excluded.description, size = excluded.size, fp = excluded.fp, chunks = excluded.chunks, status = excluded.status, owner = excluded.owner, updated = excluded.updated')
            .bind(body.id, shelf, shortText(body.name, 80) || body.id, shortText(body.version, 40), author,
                  shortText(body.description, 200), Math.floor(size), body.fp, total, status, who.id, now),
        db.prepare('DELETE FROM store_chunks WHERE id = ? AND NOT EXISTS (SELECT 1 FROM store_plugins p WHERE p.id = store_chunks.id AND p.owner = store_chunks.owner AND p.fp = store_chunks.fp)')
            .bind(body.id)
    ]);
    return json({ ok: true, status });
}

export async function storeMine(env, who) {
    const rows = await env.DB.prepare('SELECT * FROM store_plugins WHERE owner = ? ORDER BY id').bind(who.id).all();
    return json({ ok: true, items: (rows.results || []).map(storeItem) });
}

export async function storeRemove(request, env, who, asOwner) {
    const { body, err } = await readJson(request); if (err) return err;
    if (!goodPluginId(body.id)) return json({ error: 'bad_plugin' }, 400);
    const row = await env.DB.prepare('SELECT owner FROM store_plugins WHERE id = ?').bind(body.id).first();
    if (!row || (!asOwner && row.owner !== who.id)) return json({ error: 'not_found' }, 404);
    await env.DB.batch([
        env.DB.prepare('DELETE FROM store_plugins WHERE id = ?').bind(body.id),
        env.DB.prepare('DELETE FROM store_chunks WHERE id = ? AND owner = ?').bind(body.id, row.owner)
    ]);
    return json({ ok: true });
}

export async function storeOwnerAll(env) {
    const rows = await env.DB.prepare("SELECT * FROM store_plugins ORDER BY CASE status WHEN 'pending' THEN 0 ELSE 1 END, shelf, name").all();
    return json({ ok: true, items: (rows.results || []).map(storeItem) });
}

export async function storeOwnerApprove(request, env) {
    const { body, err } = await readJson(request); if (err) return err;
    if (!goodPluginId(body.id) || !goodFp(body.fp)) return json({ error: 'bad_plugin' }, 400);
    // approving names the exact version (fp) that was reviewed, so a re-upload can't slip in between
    const r = await env.DB.prepare("UPDATE store_plugins SET status = 'approved' WHERE id = ? AND fp = ? AND shelf = 'community'").bind(body.id, body.fp).run();
    if (!r.meta || !r.meta.changes) return json({ error: 'not_found' }, 404);
    return json({ ok: true });
}
