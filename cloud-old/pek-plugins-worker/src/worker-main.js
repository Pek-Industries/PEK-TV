// ===================================================================================================================
// PEK Plugins worker ("pek-plugins"). The plugin store for pekindustries.com and the PEK TV app.
//   - .PEK files live in R2 (binding PLUGINS). Names, versions, permissions, counters live in D1 (binding DB).
//   - Only .PEK files are accepted. Every upload is fully re-checked here (PekCore above), whatever the website said.
//   - Browsing is public. Downloading from the WEBSITE needs a PEK account. Uploading needs a GitHub sign-in.
//   - The PEK TV app downloads from /v1/app/... with no account.
// Setup: see SETUP.md. Settings (Workers > pek-plugins > Settings > Variables and Secrets):
//   GITHUB_CLIENT_ID (text) GITHUB_CLIENT_SECRET (secret) SITE_URL (text, https://pekindustries.com/pektv/)
//   OWNER_GITHUB (text, your GitHub username, comma separated)   PEK_ACCOUNT_API (text, optional)
//   MIN_ACCOUNT_DAYS (text, optional, default 7)   BLOCKED_GITHUB (text, optional)
// ===================================================================================================================

const DEFAULT_ACCOUNT_API = 'https://pek-sync.aquariusibeats.workers.dev';   // the PEK accounts worker (worker.js)
const ALLOWED_HOSTS = ['pekindustries.com', 'www.pekindustries.com', 'pek-tv.pages.dev', 'pek-tv.web.app'];
const ALLOWED_SUFFIX = '.aquariusibeats.workers.dev';

const MAX_SHOTS = 6, MAX_SHOT_BYTES = 2 * 1024 * 1024, MAX_ICON_BYTES = 60 * 1024;
const MAX_UPLOAD_BODY = 24 * 1024 * 1024;           // .PEK (<= 9 MB) + 6 screenshots (<= 2 MB each) + text
const MAX_PER_USER = 10;                             // community plugins one GitHub account may have
const GH_SESSION_TTL = 7 * 24 * 3600 * 1000, GH_STATE_TTL = 10 * 60 * 1000;

let CORS = {};
const json = (obj, status = 200, extra) => new Response(JSON.stringify(obj), { status, headers: Object.assign({ 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }, CORS, extra || {}) });

function csv(v) { return String(v || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean); }
function inList(list, gh) { return list.indexOf(String(gh.login).toLowerCase()) >= 0 || list.indexOf(String(gh.id)) >= 0; }
function siteUrl(env) { const u = String(env.SITE_URL || ''); return /^https:\/\//.test(u) ? (u.endsWith('/') ? u : u + '/') : ''; }
function originAllowed(origin, env) {
  if (!origin) return false;
  let u; try { u = new URL(origin); } catch (e) { return false; }
  if (u.protocol !== 'https:') return false;
  let site = ''; try { site = new URL(siteUrl(env)).hostname; } catch (e) { /* not set */ }
  return ALLOWED_HOSTS.indexOf(u.hostname) >= 0 || u.hostname.endsWith(ALLOWED_SUFFIX) || (site && u.hostname === site);
}

const enc = new TextEncoder();
const hexOf = (buf) => Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
const sha256Text = async (t) => hexOf(await crypto.subtle.digest('SHA-256', enc.encode(t)));
const randomHex = (n) => hexOf(crypto.getRandomValues(new Uint8Array(n)));
function randomToken() { const b = crypto.getRandomValues(new Uint8Array(32)); let s = ''; for (const x of b) s += String.fromCharCode(x); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
function toB64(u8) { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); }
const short = (v, max) => (typeof v === 'string' ? v.slice(0, max) : '');
const clientIp = (request) => request.headers.get('CF-Connecting-IP') || 'unknown';
const bearer = (request) => { const m = /^Bearer\s+(\S+)$/i.exec(request.headers.get('Authorization') || ''); return m && m[1].length >= 20 && m[1].length <= 100 ? m[1] : ''; };

// ------------------------------------------------------------------------------------------------ database
let ready = false;
async function init(db) {
  if (ready) return;
  await db.batch([
    db.prepare('CREATE TABLE IF NOT EXISTS throttle (k TEXT PRIMARY KEY, n INTEGER NOT NULL, reset_at INTEGER NOT NULL)'),
    db.prepare('CREATE TABLE IF NOT EXISTS gh_states (state TEXT PRIMARY KEY, ret TEXT NOT NULL, created INTEGER NOT NULL)'),
    db.prepare('CREATE TABLE IF NOT EXISTS gh_sessions (token_hash TEXT PRIMARY KEY, gh_id TEXT NOT NULL, login TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL)'),
    db.prepare(`CREATE TABLE IF NOT EXISTS plugins (
      id TEXT PRIMARY KEY, shelf TEXT NOT NULL, status TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
      owner TEXT NOT NULL, owner_login TEXT NOT NULL,
      name TEXT NOT NULL, version TEXT NOT NULL, author TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '', readme TEXT NOT NULL DEFAULT '',
      size INTEGER NOT NULL, sha256 TEXT NOT NULL, pek_key TEXT NOT NULL, icon TEXT NOT NULL DEFAULT '',
      info TEXT NOT NULL DEFAULT '{}', files TEXT NOT NULL DEFAULT '[]', shots TEXT NOT NULL DEFAULT '[]',
      dl_site INTEGER NOT NULL DEFAULT 0, dl_app INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL, updated INTEGER NOT NULL)`),
    db.prepare('CREATE INDEX IF NOT EXISTS plugins_status ON plugins (status, shelf)')
  ]);
  ready = true;
}

// Returns true when the caller is OVER the limit. Counts every call it sees.
async function limited(db, key, max, windowMs, now) {
  const row = await db.prepare('SELECT n, reset_at FROM throttle WHERE k = ?').bind(key).first();
  if (!row || row.reset_at <= now) {
    await db.prepare('INSERT INTO throttle (k, n, reset_at) VALUES (?, 1, ?) ON CONFLICT(k) DO UPDATE SET n = 1, reset_at = excluded.reset_at').bind(key, now + windowMs).run();
    return false;
  }
  if (row.n >= max) return true;
  await db.prepare('UPDATE throttle SET n = n + 1 WHERE k = ?').bind(key).run();
  return false;
}

// ------------------------------------------------------------------------------------------------ GitHub sign-in (uploads)
function siteRedirect(env, page, hash) {
  const base = siteUrl(env);
  if (!base) return json({ error: 'site_not_configured' }, 500);
  const file = page === 'owner' ? 'store-owner.html' : page === 'mine' ? 'store-mine.html' : 'store-upload.html';
  return new Response(null, { status: 302, headers: { Location: base + file + '#' + hash, 'Cache-Control': 'no-store' } });
}

async function ghLogin(url, request, env) {
  if (!env.GITHUB_CLIENT_ID || !env.GITHUB_CLIENT_SECRET || !siteUrl(env)) return json({ error: 'github_not_configured' }, 500);
  const now = Date.now();
  if (await limited(env.DB, 'gh:login:' + clientIp(request), 30, 10 * 60 * 1000, now)) return json({ error: 'rate_limited' }, 429);
  const r = url.searchParams.get('ret');
  const ret = r === 'owner' ? 'owner' : r === 'mine' ? 'mine' : 'upload';
  const state = randomHex(16);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM gh_states WHERE created < ?').bind(now - GH_STATE_TTL),
    env.DB.prepare('INSERT INTO gh_states (state, ret, created) VALUES (?, ?, ?)').bind(state, ret, now)
  ]);
  const to = 'https://github.com/login/oauth/authorize?client_id=' + encodeURIComponent(env.GITHUB_CLIENT_ID) +
    '&redirect_uri=' + encodeURIComponent(url.origin + '/v1/gh/callback') + '&state=' + state + '&allow_signup=true';
  return new Response(null, { status: 302, headers: { Location: to, 'Cache-Control': 'no-store' } });
}

async function ghCallback(url, env) {
  const now = Date.now();
  const state = url.searchParams.get('state') || '', code = url.searchParams.get('code') || '';
  const row = /^[a-f0-9]{32}$/.test(state) ? await env.DB.prepare('SELECT ret, created FROM gh_states WHERE state = ?').bind(state).first() : null;
  if (row) await env.DB.prepare('DELETE FROM gh_states WHERE state = ?').bind(state).run();   // one use only
  if (!row || row.created < now - GH_STATE_TTL) return siteRedirect(env, 'upload', 'error=expired');
  const page = row.ret;
  if (!code) return siteRedirect(env, page, 'error=denied');

  let access = '', gh = null;
  try {
    const t = await fetch('https://github.com/login/oauth/access_token', {
      method: 'POST', headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'User-Agent': 'pek-plugins' },
      body: JSON.stringify({ client_id: env.GITHUB_CLIENT_ID, client_secret: env.GITHUB_CLIENT_SECRET, code })
    });
    access = ((await t.json()) || {}).access_token || '';
    if (access) {
      const u = await fetch('https://api.github.com/user', { headers: { Authorization: 'Bearer ' + access, Accept: 'application/vnd.github+json', 'User-Agent': 'pek-plugins' } });
      if (u.ok) gh = await u.json();
    }
  } catch (e) { /* handled below */ }
  if (access) {   // we only needed to learn who this is: revoke GitHub's token straight away (best effort)
    try {
      await fetch('https://api.github.com/applications/' + encodeURIComponent(env.GITHUB_CLIENT_ID) + '/token', {
        method: 'DELETE',
        headers: { Authorization: 'Basic ' + btoa(env.GITHUB_CLIENT_ID + ':' + env.GITHUB_CLIENT_SECRET), Accept: 'application/vnd.github+json', 'User-Agent': 'pek-plugins', 'Content-Type': 'application/json' },
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
    env.DB.prepare('INSERT INTO gh_sessions (token_hash, gh_id, login, created, expires) VALUES (?, ?, ?, ?, ?)').bind(await sha256Text('pek:gh:' + token), String(gh.id), String(gh.login), now, now + GH_SESSION_TTL)
  ]);
  return siteRedirect(env, page, 'token=' + encodeURIComponent(token));
}

// Who is calling (GitHub session)? Owner / blocked status is re-checked on every call.
async function ghSession(request, env, now) {
  const t = bearer(request);
  if (!t) return null;
  const hash = await sha256Text('pek:gh:' + t);
  const r = await env.DB.prepare('SELECT gh_id, login, expires FROM gh_sessions WHERE token_hash = ?').bind(hash).first();
  if (!r || r.expires < now) return null;
  const gh = { id: r.gh_id, login: r.login };
  if (inList(csv(env.BLOCKED_GITHUB), gh)) return null;
  return { id: 'gh:' + r.gh_id, login: r.login, owner: inList(csv(env.OWNER_GITHUB), gh), hash };
}

// ------------------------------------------------------------------------------------------------ PEK account (website downloads)
// The website sends the visitor's PEK session token. We ask the PEK accounts worker "who is this?" (GET /v1/me).
// Nothing about the account is stored here except a hash of the email, used for a download rate limit.
const pekCache = new Map();
async function pekAccount(request, env) {
  const t = bearer(request);
  if (!t) return null;
  const hit = pekCache.get(t);
  if (hit && hit.until > Date.now()) return hit.v;
  let v = null;
  try {
    const r = await fetch(String(env.PEK_ACCOUNT_API || DEFAULT_ACCOUNT_API).replace(/\/+$/, '') + '/v1/me', { headers: { Authorization: 'Bearer ' + t } });
    if (r.status === 401) v = null;
    else if (!r.ok) return { down: true };
    else { const j = await r.json(); v = j && j.ok && j.email ? { email: String(j.email), username: String(j.username || '') } : null; }
  } catch (e) { return { down: true }; }
  if (pekCache.size > 500) pekCache.clear();
  pekCache.set(t, { v, until: Date.now() + (v ? 60000 : 10000) });
  return v;
}

// ------------------------------------------------------------------------------------------------ listing
function card(r, inlineIcon) {
  const info = safeJson(r.info, {});
  return {
    id: r.id, shelf: r.shelf, name: r.name, version: r.version, author: r.author, description: r.description, size: r.size,
    sha256: r.sha256, fp: r.sha256.slice(0, 16), chunks: 0, updated: r.updated, status: r.status,
    permissions: info.permissions || [], network: info.network || [],
    shots: safeJson(r.shots, []).length, hasIcon: !!r.icon, icon: inlineIcon ? r.icon : undefined,
    downloads: r.dl_site + r.dl_app
  };
}
function safeJson(s, dflt) { try { const v = JSON.parse(s); return v == null ? dflt : v; } catch (e) { return dflt; } }

async function listPlugins(url, env) {
  const shelf = url.searchParams.get('shelf');
  const q = short(url.searchParams.get('q') || '', 60).toLowerCase().trim();
  const inline = url.searchParams.get('inline_icons') === '1';
  const where = ["status = 'approved'"], bind = [];
  if (shelf === 'official' || shelf === 'community') { where.push('shelf = ?'); bind.push(shelf); }
  if (q) { where.push("(lower(name) LIKE ? ESCAPE '\\' OR lower(description) LIKE ? ESCAPE '\\' OR lower(author) LIKE ? ESCAPE '\\' OR id LIKE ? ESCAPE '\\')"); const like = '%' + q.replace(/[\\%_]/g, (c) => '\\' + c) + '%'; bind.push(like, like, like, like); }
  const cols = 'id, shelf, status, name, version, author, description, size, sha256, info, shots, dl_site, dl_app, updated' + (inline ? ', icon' : ", substr(icon, 1, 1) AS icon");
  const rows = await env.DB.prepare('SELECT ' + cols + ' FROM plugins WHERE ' + where.join(' AND ') + " ORDER BY CASE shelf WHEN 'official' THEN 0 ELSE 1 END, name LIMIT 200").bind(...bind).all();
  const items = (rows.results || []).map((r) => card(r, inline));
  return json({ ok: true, items }, 200, { 'Cache-Control': 'public, max-age=60' });
}

async function canSee(row, request, env) {
  if (row.status === 'approved') return true;
  const who = await ghSession(request, env, Date.now());
  return !!(who && (who.owner || who.id === row.owner));
}

async function getPlugin(id, request, env) {
  const row = await env.DB.prepare('SELECT * FROM plugins WHERE id = ?').bind(id).first();
  if (!row) return json({ error: 'not_found' }, 404);
  if (!(await canSee(row, request, env))) return json({ error: 'not_found' }, 404);
  const c = card(row, false);
  const info = safeJson(row.info, {});
  return json(Object.assign(c, { ok: true, details: row.details, readme: row.readme, uploader: row.owner_login, lines: info.lines || [], navTab: info.navTab || '', hasPython: !!info.hasPython, files: safeJson(row.files, []), note: row.note, created: row.created }));
}

async function getIcon(id, request, env) {
  const row = await env.DB.prepare('SELECT icon, status, owner FROM plugins WHERE id = ?').bind(id).first();
  if (!row || !row.icon || !(await canSee(row, request, env))) return new Response('not found', { status: 404, headers: CORS });
  const m = /^data:(image\/(?:png|jpeg|webp));base64,(.+)$/.exec(row.icon);
  if (!m) return new Response('not found', { status: 404, headers: CORS });
  const bin = atob(m[2]), u8 = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  return new Response(u8, { headers: Object.assign({ 'Content-Type': m[1], 'X-Content-Type-Options': 'nosniff', 'Cache-Control': row.status === 'approved' ? 'public, max-age=3600' : 'private, no-store' }, CORS) });
}

async function getShot(id, n, request, env) {
  const row = await env.DB.prepare('SELECT shots, status, owner FROM plugins WHERE id = ?').bind(id).first();
  if (!row || !(await canSee(row, request, env))) return new Response('not found', { status: 404, headers: CORS });
  const key = safeJson(row.shots, [])[n];
  const obj = key ? await env.PLUGINS.get(key) : null;
  if (!obj) return new Response('not found', { status: 404, headers: CORS });
  const type = key.endsWith('.png') ? 'image/png' : key.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
  return new Response(obj.body, { headers: Object.assign({ 'Content-Type': type, 'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "default-src 'none'; sandbox", 'Cache-Control': row.status === 'approved' ? 'public, max-age=86400' : 'private, no-store' }, CORS) });
}

// ------------------------------------------------------------------------------------------------ downloads
async function sendPek(row, env, counter) {
  const obj = await env.PLUGINS.get(row.pek_key);
  if (!obj) return json({ error: 'not_found' }, 404);
  await env.DB.prepare('UPDATE plugins SET ' + counter + ' = ' + counter + ' + 1 WHERE id = ?').bind(row.id).run();
  return new Response(obj.body, {
    headers: Object.assign({
      'Content-Type': 'application/octet-stream', 'Content-Length': String(obj.size),
      'Content-Disposition': 'attachment; filename="' + row.id + '.PEK"', 'X-Content-Type-Options': 'nosniff',
      'X-PEK-SHA256': row.sha256, 'Access-Control-Expose-Headers': 'X-PEK-SHA256, Content-Disposition', 'Cache-Control': 'no-store'
    }, CORS)
  });
}

// WEBSITE download: needs a PEK account.
async function siteDownload(id, request, env) {
  const acct = await pekAccount(request, env);
  if (acct && acct.down) return json({ error: 'account_service_down' }, 503);
  if (!acct) return json({ error: 'pek_account_required' }, 401);
  const now = Date.now();
  if (await limited(env.DB, 'dl:acct:' + (await sha256Text('pek:acct:' + acct.email)), 100, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
  const row = await env.DB.prepare("SELECT id, pek_key, sha256 FROM plugins WHERE id = ? AND status = 'approved'").bind(id).first();
  if (!row) return json({ error: 'not_found' }, 404);
  return sendPek(row, env, 'dl_site');
}

// APP download: no account. (The app is the one place a plugin installs, and it checks the file again itself.)
async function appDownload(id, request, env) {
  const now = Date.now();
  if (await limited(env.DB, 'dl:app:' + clientIp(request), 120, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
  const row = await env.DB.prepare("SELECT id, pek_key, sha256 FROM plugins WHERE id = ? AND status = 'approved'").bind(id).first();
  if (!row) return json({ error: 'not_found' }, 404);
  return sendPek(row, env, 'dl_app');
}

// ------------------------------------------------------------------------------------------------ upload
const fail = (error, message, extra) => json(Object.assign({ ok: false, error, message }, extra || {}), error === 'rate_limited' ? 429 : 400);

async function upload(request, env, who) {
  const db = env.DB, now = Date.now();
  const len = Number(request.headers.get('Content-Length') || 0);
  if (!len || len > MAX_UPLOAD_BODY) return json({ ok: false, error: 'too_large', message: 'That upload is too large (limit 8 MB for the plugin and 2 MB per screenshot).' }, 413);
  if (!who.owner && await limited(db, 'up:' + who.id, 20, 24 * 3600 * 1000, now)) return fail('rate_limited', 'Too many uploads today. Please try again tomorrow.');

  let form;
  try { form = await request.formData(); } catch (e) { return fail('bad_form', 'The upload could not be read.'); }
  const file = form.get('pek');
  if (!file || typeof file === 'string') return fail('no_file', 'Choose a .PEK file.');
  if (!/\.pek$/i.test(file.name || '')) return fail('not_pek', 'Only .PEK files are accepted. Plain .zip files are not.');
  if (file.size > PekCore.MAX_PEK) return fail('too_large', 'That file is too large (limit about 9 MB).');

  const official = who.owner && form.get('shelf') === 'official';
  let pek;
  const bytes = new Uint8Array(await file.arrayBuffer());
  try { pek = await PekCore.read(bytes); }
  catch (e) { if (e instanceof PekCore.Reject) return fail('bad_pek', 'REJECTED: ' + e.message); throw e; }
  const verdict = PekCore.check(pek, { owner: official });
  if (verdict.problems.length) return fail('invalid_plugin', 'This is not an acceptable PEK plugin.', { problems: verdict.problems });

  const id = pek.id, info = verdict.info, manifest = verdict.manifest;
  const cur = await db.prepare('SELECT owner, shelf, shots, pek_key, sha256, created FROM plugins WHERE id = ?').bind(id).first();
  if (cur && !official && (cur.shelf === 'official' || cur.owner !== who.id)) return fail('id_taken', 'Something in the store already uses the id "' + id + '". Repack your plugin with another id.');
  if (!official) {
    const mine = await db.prepare("SELECT COUNT(*) AS n FROM plugins WHERE owner = ? AND shelf = 'community' AND id != ?").bind(who.id, id).first();
    if (mine && mine.n >= MAX_PER_USER) return fail('store_quota', 'You already have ' + MAX_PER_USER + ' plugins in the store. Remove one first.');
  }

  // screenshots
  const shots = form.getAll('shots').filter((f) => f && typeof f !== 'string' && f.size > 0);
  if (shots.length > MAX_SHOTS) return fail('too_many_shots', 'At most ' + MAX_SHOTS + ' screenshots.');
  const shotData = [];
  for (const s of shots) {
    if (s.size > MAX_SHOT_BYTES) return fail('shot_too_large', 'Screenshot "' + short(s.name, 40) + '" is larger than 2 MB.');
    const u8 = new Uint8Array(await s.arrayBuffer());
    const type = PekCore.imageType(u8);
    if (!type) return fail('shot_type', 'Screenshot "' + short(s.name, 40) + '" is not a PNG, JPG or WebP picture.');
    shotData.push({ u8, type });
  }

  // icon (from plugin.json "icon"): kept small, shown on the listing
  let icon = '';
  const warnings = verdict.warnings.slice();
  if (typeof manifest.icon === 'string') {
    const f = pek.files.find((x) => x.path === manifest.icon);
    const t = f ? PekCore.imageType(f.data) : '';
    if (f && t && f.data.length <= MAX_ICON_BYTES) icon = 'data:' + (t === 'png' ? 'image/png' : t === 'webp' ? 'image/webp' : 'image/jpeg') + ';base64,' + toB64(f.data);
    else warnings.push('The icon is missing, not a PNG/JPG/WebP picture, or larger than 60 KB, so the store will show a placeholder.');
  }
  const readmeFile = pek.files.find((f) => f.path.toLowerCase() === 'readme.md');
  const readme = readmeFile ? new TextDecoder('utf-8').decode(readmeFile.data).slice(0, 8000) : '';
  const details = short(form.get('details'), 4000).trim();

  // store: R2 first, then the database row, then clean up what the new version replaces
  const pekKey = 'pek/' + id + '/' + pek.sha256 + '.PEK';
  await env.PLUGINS.put(pekKey, bytes, { httpMetadata: { contentType: 'application/octet-stream' } });
  let shotKeys = cur ? safeJson(cur.shots, []) : [];
  const oldShots = shotKeys.slice();
  if (shotData.length) {
    shotKeys = [];
    for (let i = 0; i < shotData.length; i++) {
      const key = 'shots/' + id + '/' + pek.sha256.slice(0, 12) + '-' + (i + 1) + '.' + shotData[i].type;
      await env.PLUGINS.put(key, shotData[i].u8, { httpMetadata: { contentType: shotData[i].type === 'png' ? 'image/png' : shotData[i].type === 'webp' ? 'image/webp' : 'image/jpeg' } });
      shotKeys.push(key);
    }
  }
  const shelf = official ? 'official' : 'community';
  const status = official ? 'approved' : 'pending';                       // community uploads wait for the owner
  const author = official ? (info.author || who.login) : who.login;       // on Community the author is the signed-in GitHub account
  const filesList = pek.files.map((f) => ({ path: f.path, size: f.data.length }));
  await db.prepare(
    'INSERT INTO plugins (id, shelf, status, note, owner, owner_login, name, version, author, description, details, readme, size, sha256, pek_key, icon, info, files, shots, created, updated) ' +
    "VALUES (?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " +
    'ON CONFLICT(id) DO UPDATE SET shelf = excluded.shelf, status = excluded.status, note = \'\', owner = excluded.owner, owner_login = excluded.owner_login, name = excluded.name, version = excluded.version, ' +
    'author = excluded.author, description = excluded.description, details = excluded.details, readme = excluded.readme, size = excluded.size, sha256 = excluded.sha256, pek_key = excluded.pek_key, ' +
    'icon = excluded.icon, info = excluded.info, files = excluded.files, shots = excluded.shots, updated = excluded.updated'
  ).bind(id, shelf, status, who.id, who.login, info.name || id, info.version, author, info.description, details, readme, file.size, pek.sha256, pekKey, icon, JSON.stringify({ permissions: info.permissions, network: info.network, lines: info.lines, navTab: info.navTab, hasPython: info.hasPython }), JSON.stringify(filesList), JSON.stringify(shotKeys), cur ? cur.created : now, now).run();
  if (cur && cur.pek_key && cur.pek_key !== pekKey) await env.PLUGINS.delete(cur.pek_key);
  if (shotData.length) for (const k of oldShots) if (shotKeys.indexOf(k) < 0) await env.PLUGINS.delete(k);
  return json({ ok: true, id, status, shelf, warnings });
}

async function mine(env, who) {
  const rows = await env.DB.prepare('SELECT id, shelf, status, note, name, version, author, description, size, sha256, info, shots, dl_site, dl_app, updated, substr(icon, 1, 1) AS icon FROM plugins WHERE owner = ? ORDER BY id').bind(who.id).all();
  return json({ ok: true, items: (rows.results || []).map((r) => Object.assign(card(r, false), { note: r.note })) });
}

async function removePlugin(env, id, who, asOwner) {
  const row = await env.DB.prepare('SELECT owner, pek_key, shots FROM plugins WHERE id = ?').bind(id).first();
  if (!row || (!asOwner && row.owner !== who.id)) return json({ error: 'not_found' }, 404);
  await env.DB.prepare('DELETE FROM plugins WHERE id = ?').bind(id).run();
  await env.PLUGINS.delete([row.pek_key].concat(safeJson(row.shots, [])));
  return json({ ok: true });
}

async function ownerAll(env) {
  const rows = await env.DB.prepare("SELECT id, shelf, status, note, name, version, author, description, size, sha256, info, shots, dl_site, dl_app, updated, owner_login, substr(icon, 1, 1) AS icon FROM plugins ORDER BY CASE status WHEN 'pending' THEN 0 ELSE 1 END, shelf, name").all();
  return json({ ok: true, items: (rows.results || []).map((r) => Object.assign(card(r, false), { note: r.note, uploader: r.owner_login })) });
}

async function ownerDownload(url, env) {
  const id = url.searchParams.get('id') || '';
  const row = PekCore.validId(id) ? await env.DB.prepare('SELECT id, pek_key, sha256 FROM plugins WHERE id = ?').bind(id).first() : null;
  if (!row) return json({ error: 'not_found' }, 404);
  const obj = await env.PLUGINS.get(row.pek_key);
  if (!obj) return json({ error: 'not_found' }, 404);
  return new Response(obj.body, { headers: Object.assign({ 'Content-Type': 'application/octet-stream', 'Cache-Control': 'no-store', 'X-PEK-SHA256': row.sha256, 'Access-Control-Expose-Headers': 'X-PEK-SHA256' }, CORS) });
}

async function readBody(request) {
  const text = await request.text();
  if (text.length > 20000) return null;
  try { const b = text ? JSON.parse(text) : {}; return b && typeof b === 'object' ? b : null; } catch (e) { return null; }
}

// ------------------------------------------------------------------------------------------------ router
export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin');
    CORS = originAllowed(origin, env)
      ? { 'Access-Control-Allow-Origin': origin, 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Max-Age': '86400', Vary: 'Origin' }
      : { 'Access-Control-Allow-Origin': '*' };
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
    const url = new URL(request.url), path = url.pathname, method = request.method;
    if (path === '/' && method === 'GET') return new Response('pek-plugins ok', { headers: { 'Content-Type': 'text/plain' } });
    try {
      if (!env.DB) return json({ error: 'no_database_bound' }, 500);
      if (!env.PLUGINS) return json({ error: 'no_r2_bucket_bound' }, 500);
      await init(env.DB);
      let m;

      // public
      if (method === 'GET' && path === '/v1/plugins') return await listPlugins(url, env);
      if (method === 'GET' && (m = /^\/v1\/plugins\/([a-z0-9][a-z0-9_-]{0,39})$/.exec(path))) return await getPlugin(m[1], request, env);
      if (method === 'GET' && (m = /^\/v1\/plugins\/([a-z0-9][a-z0-9_-]{0,39})\/icon$/.exec(path))) return await getIcon(m[1], request, env);
      if (method === 'GET' && (m = /^\/v1\/plugins\/([a-z0-9][a-z0-9_-]{0,39})\/shot\/(\d)$/.exec(path))) return await getShot(m[1], Number(m[2]), request, env);
      if (method === 'GET' && (m = /^\/v1\/plugins\/([a-z0-9][a-z0-9_-]{0,39})\/download$/.exec(path))) return await siteDownload(m[1], request, env);       // PEK account
      if (method === 'GET' && (m = /^\/v1\/app\/plugins\/([a-z0-9][a-z0-9_-]{0,39})\/download$/.exec(path))) return await appDownload(m[1], request, env);   // the app, no account
      if (method === 'GET' && path === '/v1/pek/me') {                       // lets the website show "signed in as ..."
        const a = await pekAccount(request, env);
        if (a && a.down) return json({ error: 'account_service_down' }, 503);
        return a ? json({ ok: true, username: a.username }) : json({ error: 'bad_session' }, 401);
      }

      // GitHub sign-in
      if (method === 'GET' && path === '/v1/gh/login') return await ghLogin(url, request, env);
      if (method === 'GET' && path === '/v1/gh/callback') return await ghCallback(url, env);

      // everything below needs a GitHub session
      const who = await ghSession(request, env, Date.now());
      if (!who) return json({ error: 'bad_session' }, 401);
      if (method === 'GET' && path === '/v1/gh/me') return json({ ok: true, login: who.login, owner: who.owner });
      if (method === 'POST' && path === '/v1/gh/logout') { await env.DB.prepare('DELETE FROM gh_sessions WHERE token_hash = ?').bind(who.hash).run(); return json({ ok: true }); }
      if (method === 'POST' && path === '/v1/upload') return await upload(request, env, who);
      if (method === 'GET' && path === '/v1/mine') return await mine(env, who);
      if (method === 'POST' && path === '/v1/mine/remove') { const b = await readBody(request); return b && PekCore.validId(b.id) ? await removePlugin(env, b.id, who, false) : json({ error: 'bad_plugin' }, 400); }

      if (path.indexOf('/v1/owner/') === 0) {
        if (!who.owner) return json({ error: 'forbidden' }, 403);
        if (method === 'GET' && path === '/v1/owner/all') return await ownerAll(env);
        if (method === 'GET' && path === '/v1/owner/download') return await ownerDownload(url, env);
        const b = method === 'POST' ? await readBody(request) : null;
        if (!b || !PekCore.validId(b.id)) return json({ error: 'bad_plugin' }, 400);
        if (path === '/v1/owner/approve') {       // names the exact file (sha256) that was reviewed, so a re-upload can't slip in between
          if (typeof b.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(b.sha256)) return json({ error: 'bad_plugin' }, 400);
          const r = await env.DB.prepare("UPDATE plugins SET status = 'approved', note = '' WHERE id = ? AND sha256 = ? AND shelf = 'community'").bind(b.id, b.sha256).run();
          return r.meta && r.meta.changes ? json({ ok: true }) : json({ error: 'not_found' }, 404);
        }
        if (path === '/v1/owner/reject') {
          if (typeof b.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(b.sha256)) return json({ error: 'bad_plugin' }, 400);
          const r = await env.DB.prepare("UPDATE plugins SET status = 'rejected', note = ? WHERE id = ? AND sha256 = ? AND shelf = 'community'").bind(short(b.note, 200), b.id, b.sha256).run();
          return r.meta && r.meta.changes ? json({ ok: true }) : json({ error: 'not_found' }, 404);
        }
        if (path === '/v1/owner/remove') return await removePlugin(env, b.id, who, true);
      }
      return json({ error: 'not_found' }, 404);
    } catch (e) {
      console.error('worker error', String((e && e.stack) || e));
      return json({ error: 'server_error' }, 500);
    }
  }
};
