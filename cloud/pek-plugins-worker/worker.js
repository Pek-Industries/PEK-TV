// PEK core: reads and checks a .PEK plugin file (format version 1, see PEK_FORMAT.md).
// One source, two homes: it is pasted into the Cloudflare Worker (the server re-checks every upload) and shipped as
// public/pektv/store/js/pek.js (the browser previews an upload before it is sent). It must agree with
// tools/pektool.py and flutter_ui/lib/src/plugin_pek.dart: change the format in all three.
//
// No imports, no DOM. Needs: crypto.subtle, DecompressionStream('deflate-raw'), TextDecoder (Workers, browsers, Node 18+).
const PekCore = (() => {
  const MAGIC = [0x89, 0x50, 0x45, 0x4B, 0x0D, 0x0A, 0x1A, 0x0A];
  const HEADER = 64, FOOTER = 32, ENTRY = 52;
  const MAX_FILES = 200, MAX_FILE = 2 * 1024 * 1024, MAX_TOTAL = 8 * 1024 * 1024, MAX_MANIFEST = 16 * 1024;
  const MAX_PY = 200 * 1024, MAX_PATH = 120, MAX_DEPTH = 6, MAX_PEK = MAX_TOTAL + 1024 * 1024;
  const OK_EXT = ['json', 'css', 'md', 'txt', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'woff', 'woff2', 'ttf', 'otf', 'py'];
  const RESERVED_HOST = 'hesper-tmdb.aquariusibeats.workers.dev';
  const BUILTIN_IDS = ['weather', 'tmdb-discover', 'skin-maker', 'sample_scraper', 'sample_counter'];
  const OWNER_ONLY_IDS = ['trakt', 'm3u8'];   // owner may publish these on the Official shelf; nobody else may use them
  const PERMISSIONS = ['storage', 'library', 'torrent', 'favorites', 'providers', 'plugins', 'watched', 'playback', 'send', 'skins', 'live', 'epg', 'device'];

  class Reject extends Error { constructor(msg) { super(msg); this.name = 'PekReject'; } }
  const no = (m) => new Reject(m);

  const hex = (u8) => Array.from(u8, (b) => b.toString(16).padStart(2, '0')).join('');
  async function sha256(u8) { return new Uint8Array(await crypto.subtle.digest('SHA-256', u8)); }
  async function sha256Hex(u8) { return hex(await sha256(u8)); }
  const same = (a, b) => { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i]; return d === 0; };
  const extOf = (p) => { const n = p.split('/').pop(); const i = n.lastIndexOf('.'); return i < 0 ? '' : n.slice(i + 1).toLowerCase(); };
  const validId = (s) => typeof s === 'string' && /^[a-z0-9][a-z0-9_-]{0,39}$/.test(s);

  let crcTable = null;
  function crc32(u8) {
    if (!crcTable) { crcTable = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); crcTable[n] = c >>> 0; } }
    let crc = 0xFFFFFFFF;
    for (let i = 0; i < u8.length; i++) crc = crcTable[(crc ^ u8[i]) & 0xff] ^ (crc >>> 8);
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  // Raw deflate, cut off as soon as the output would pass `cap` bytes (a "zip bomb" cannot grow).
  async function inflate(src, cap, path) {
    const ds = new DecompressionStream('deflate-raw');
    const w = ds.writable.getWriter();
    const writing = w.write(src).then(() => w.close()).catch(() => {});
    const r = ds.readable.getReader();
    const out = new Uint8Array(cap);
    let n = 0;
    try {
      for (;;) {
        const { value, done } = await r.read();
        if (done) break;
        if (n + value.length > cap) { try { await r.cancel(); } catch (e) { /* stop */ } throw no(path + ': unpacks to more than its declared size (damaged or hostile file).'); }
        out.set(value, n); n += value.length;
      }
    } catch (e) {
      if (e instanceof Reject) throw e;
      throw no(path + ': the compressed data is damaged.');
    }
    await writing;
    return out.subarray(0, n);
  }

  function checkPath(p) {
    if (!p) return 'a file has an empty name';
    if (new TextEncoder().encode(p).length > MAX_PATH) return 'a file path is too long: ' + p.slice(0, 40) + '...';
    if (p[0] === '/') return 'absolute paths are not allowed: ' + p;
    let depth = 0;
    for (const part of p.split('/')) {
      if (part === '') return 'bad path (empty folder name): ' + p;
      if (part === '.' || part === '..') return 'bad path (. or ..): ' + p;
      if (part[0] === '.') return 'hidden files are not allowed: ' + p;
      if (new TextEncoder().encode(part).length > 64) return 'a file or folder name is too long in: ' + p;
      if (/[. ]$/.test(part)) return 'bad file name: ' + p;
      if (/[\u0000-\u001f\u007f\\:*?"<>|]/.test(part)) return 'bad character in file name: ' + p;
      if (++depth > MAX_DEPTH) return 'folders are nested too deeply: ' + p;
    }
    return '';
  }

  // Parses and fully verifies a .PEK. Throws Reject (message = the reason) on the first problem.
  // Returns { id, files: [{ path, data }], sha256 (hex of the whole file), size }.
  async function read(input) {
    const u8 = input instanceof Uint8Array ? input : new Uint8Array(input);
    const n = u8.length;
    if (n >= 4 && u8[0] === 0x50 && u8[1] === 0x4B && (u8[2] === 3 || u8[2] === 5 || u8[2] === 7)) throw no('this is a .zip file. PEK only accepts .PEK plugins. Convert it with: python tools/pektool.py convert yourplugin.zip');
    if (n > MAX_PEK) throw no('the file is bigger than any valid .PEK can be (limit about 9 MB).');
    if (n < HEADER + FOOTER) throw no('the file is only ' + n + ' bytes: too short to be a .PEK.');
    for (let i = 0; i < 8; i++) if (u8[i] !== MAGIC[i]) throw no('this is not a .PEK file (wrong signature).');
    const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    const u64 = (o) => { const v = dv.getBigUint64(o, true); if (v > 0x1FFFFFFFFFFFFFn) throw no('a number in the header is impossibly large.'); return Number(v); };
    if (crc32(u8.subarray(0, 60)) !== dv.getUint32(60, true)) throw no('the header checksum is wrong: the file is damaged.');
    const version = dv.getUint16(8, true);
    if (version !== 1) throw no('unsupported .PEK format version ' + version + ' (this site understands version 1).');
    if (dv.getUint16(10, true) !== 0) throw no('the file uses features this site does not understand (unknown flags).');
    for (let i = 48; i < 60; i++) if (u8[i] !== 0) throw no('the reserved header bytes are not zero.');
    const count = dv.getUint32(12, true), tocOff = u64(16), tocLen = u64(24);
    if (u64(32) !== HEADER) throw no('the data area does not start where it should.');
    if (u64(40) !== n) throw no('the file size does not match its header: it is cut short or has extra bytes.');
    if (tocOff < HEADER || tocOff > n || tocLen > n || tocOff + tocLen !== n - FOOTER) throw no('the table of contents does not fit the file.');
    if (count > MAX_FILES) throw no('the plugin has too many files (limit ' + MAX_FILES + ').');
    const whole = await sha256(u8.subarray(0, n - FOOTER));
    if (!same(whole, u8.subarray(n - FOOTER))) throw no('the file was modified or damaged after it was packed (SHA-256 does not match).');

    const toc = u8.subarray(tocOff, tocOff + tocLen), tv = new DataView(toc.buffer, toc.byteOffset, toc.byteLength);
    if (!toc.length || 1 + toc[0] > toc.length) throw no('the table of contents is cut short.');
    const idLen = toc[0];
    let id = '';
    for (let i = 0; i < idLen; i++) { if (toc[1 + i] > 127) throw no('the plugin id is not plain ASCII.'); id += String.fromCharCode(toc[1 + i]); }
    if (!validId(id)) throw no('the plugin id "' + id + '" is not valid (1-40 lowercase letters, digits, - or _).');

    let cur = 1 + idLen;
    const entries = [], dec = new TextDecoder('utf-8', { fatal: true });
    for (let k = 0; k < count; k++) {
      if (cur + ENTRY > toc.length) throw no('the table of contents is cut short at file ' + (k + 1) + ' of ' + count + '.');
      const plen = tv.getUint16(cur, true), method = toc[cur + 2], eflags = toc[cur + 3];
      const off = Number(tv.getBigUint64(cur + 4, true)), stored = tv.getUint32(cur + 12, true), raw = tv.getUint32(cur + 16, true);
      const digest = toc.subarray(cur + 20, cur + 52);
      cur += ENTRY;
      if (cur + plen > toc.length) throw no('the table of contents is cut short inside a file name.');
      let path;
      try { path = dec.decode(toc.subarray(cur, cur + plen)); } catch (e) { throw no('a file name in the plugin is not valid UTF-8.'); }
      cur += plen;
      entries.push({ path, method, eflags, off, stored, raw, digest });
    }
    if (cur !== toc.length) throw no('unexpected extra bytes after the table of contents.');

    // The entries must tile the data area exactly: a gap could hide data, an overlap could confuse the reader.
    let expect = HEADER;
    for (const e of entries.slice().sort((a, b) => a.off - b.off)) {
      if (e.off !== expect) throw no(e.path + ': unaccounted data or overlapping files inside the plugin.');
      if (e.off + e.stored > tocOff) throw no(e.path + ': its data lies outside the data area.');
      expect = e.off + e.stored;
    }
    if (expect !== tocOff) throw no('unaccounted data between the last file and the table of contents.');

    const files = [], seen = new Set();
    let total = 0;
    for (const e of entries) {
      const low = e.path.toLowerCase();
      if (seen.has(low)) throw no('the same file appears twice: ' + e.path);
      seen.add(low);
      if (e.method !== 0 && e.method !== 1) throw no(e.path + ': unknown compression method ' + e.method + '.');
      if (e.eflags !== 0) throw no(e.path + ': unknown file flags.');
      if (e.raw > MAX_FILE) throw no(e.path + ' is too large (limit 2 MB per file).');
      total += e.raw;
      if (total > MAX_TOTAL) throw no('the plugin is too large (limit 8 MB in total).');
      const blob = u8.subarray(e.off, e.off + e.stored);
      let data;
      if (e.method === 0) { if (e.stored !== e.raw) throw no(e.path + ': stored size and real size disagree.'); data = blob.slice(); }
      else { data = await inflate(blob, e.raw, e.path); if (data.length !== e.raw) throw no(e.path + ': unpacks to the wrong size (damaged file).'); }
      if (!same(await sha256(data), e.digest)) throw no(e.path + ': contents do not match their SHA-256 (damaged or changed).');
      files.push({ path: e.path, data });
    }
    return { id, files, sha256: await sha256Hex(u8), size: n };
  }

  // The plugin rules (mirrors backend/plugin_install.h and tools/pektool.py check_plugin).
  // opts.owner = true: the owner may use built-in ids and the reserved official host.
  // Returns { problems: [], warnings: [], manifest, info }.
  function check(pek, opts) {
    const owner = !!(opts && opts.owner);
    const P = [], W = [];
    const byPath = new Map(pek.files.map((f) => [f.path, f.data]));
    let manifest = null;
    if (!owner && BUILTIN_IDS.indexOf(pek.id) >= 0) P.push('"' + pek.id + '" is the id of a built-in PEK TV plugin. Choose another id (the folder name when you pack it).');
    if (!owner && OWNER_ONLY_IDS.indexOf(pek.id) >= 0) P.push('"' + pek.id + '" is reserved for the PEK owner. Choose another id.');
    let total = 0;
    for (const f of pek.files) {
      const why = checkPath(f.path);
      if (why) { P.push(why); continue; }
      total += f.data.length;
      const ext = extOf(f.path);
      if (ext === 'js' || ext === 'mjs') P.push("plugins can't include JavaScript (" + f.path + '). PEK TV only installs plugins written in Python (screen.py).');
      else if (OK_EXT.indexOf(ext) < 0) P.push('file type not allowed in plugins: ' + f.path);
      else if (ext === 'py' && f.data.length > MAX_PY) P.push(f.path + ' is too large for a plugin backend (limit 200 KB).');
    }
    if (total > MAX_TOTAL) P.push('the plugin is too large (limit 8 MB in total).');
    if (byPath.has('skin.json')) P.push('this is a skin, not a plugin. Skins are not accepted here.');
    if (!byPath.has('plugin.json')) P.push('plugin.json is missing (it must sit at the top level of the plugin).');
    else {
      const raw = byPath.get('plugin.json');
      if (raw.length > MAX_MANIFEST) P.push('plugin.json is too large (limit 16 KB).');
      let text = '';
      try { text = new TextDecoder('utf-8', { fatal: true }).decode(raw).replace(/^\uFEFF/, ''); manifest = JSON.parse(text); }
      catch (e) { P.push('plugin.json is not valid JSON.'); }
      if (manifest !== null && (typeof manifest !== 'object' || Array.isArray(manifest))) { P.push('plugin.json is not a JSON object.'); manifest = null; }
      if (manifest) {
        if (!owner && text.toLowerCase().indexOf(RESERVED_HOST) >= 0) P.push(RESERVED_HOST + " is reserved for PEK's official plugins.");
        if (!(typeof manifest.name === 'string' && manifest.name.trim())) P.push('plugin.json needs a "name".');
        if (!(typeof manifest.version === 'string' && manifest.version.trim())) P.push('plugin.json needs a "version" (text such as "1.0.0").');
        const fl = manifest.flutter;
        if (!fl || typeof fl !== 'object' || Array.isArray(fl)) P.push('plugin.json needs a "flutter" entry, for example "flutter": { "screen": "screen.py" }.');
        else if (typeof fl.screen !== 'string' || !fl.screen) P.push('"flutter" needs a "screen" file name.');
        else if (!byPath.has(fl.screen)) P.push('"flutter.screen" points at ' + fl.screen + ', which is not in the plugin.');
        if (manifest.icon != null && (typeof manifest.icon !== 'string' || !byPath.has(manifest.icon))) P.push('"icon" points at a file that is not in the plugin.');
        const perms = manifest.permissions;
        if (perms != null) {
          if (typeof perms !== 'object' || Array.isArray(perms)) P.push('"permissions" must be an object.');
          else if (perms.network != null && !(Array.isArray(perms.network) && perms.network.every((x) => typeof x === 'string' && x))) P.push('"permissions.network" must be a list of host names.');
        }
        if (manifest.ui != null && (typeof manifest.ui !== 'object' || Array.isArray(manifest.ui))) P.push('"ui" must be an object.');
        if (!manifest.description) W.push('plugin.json has no "description"; the store card will be empty.');
        if (!manifest.icon) W.push('plugin.json has no "icon"; the store will show a plain placeholder.');
        if (pek.files.some((f) => extOf(f.path) === 'py') && perms == null) W.push('the plugin has Python files but declares no "permissions"; the app will not run a backend without them.');
      }
    }
    if (!byPath.has('screen.py')) P.push('screen.py is missing. PEK TV only installs plugins with a Python screen.');
    return { problems: P, warnings: W, manifest, info: manifest ? describe(manifest, pek.files) : null };
  }

  // What the plugin asks for, in plain words (shown on the store page).
  function describe(m, files) {
    const perm = m.permissions && typeof m.permissions === 'object' ? m.permissions : {};
    const network = Array.isArray(perm.network) ? perm.network.filter((x) => typeof x === 'string' && /^(\*\.)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(x)).slice(0, 20) : [];
    const on = PERMISSIONS.filter((p) => perm[p] === true);
    const says = {
      storage: 'Keeps its own private data', library: 'Python code can read titles and years in your library', torrent: 'Can search for releases and start torrent streams',
      favorites: 'Can change Favorites', providers: 'Shows "Watch on..." buttons', plugins: 'Can open other plugins', watched: 'Can read and change watched marks',
      playback: 'Can start playback', send: 'Can send things to other devices', skins: 'Can add and change skins', live: 'Can supply live TV channels', epg: 'Can supply a TV guide'
    };
    return {
      name: String(m.name || '').slice(0, 60), version: String(m.version || '').slice(0, 20), author: String(m.author || '').slice(0, 80),
      description: String(m.description || '').slice(0, 200), network, permissions: on,
      lines: [network.length ? 'Can connect to: ' + network.join(', ') : 'No network access'].concat(on.map((p) => says[p] || p)),
      navTab: m.ui && typeof m.ui.navTab === 'string' ? m.ui.navTab.slice(0, 20) : '',
      hasPython: files.some((f) => extOf(f.path) === 'py')
    };
  }

  // Image sniffing: the file's real type from its first bytes (never trust a file name).
  function imageType(u8) {
    if (u8.length > 8 && u8[0] === 0x89 && u8[1] === 0x50 && u8[2] === 0x4E && u8[3] === 0x47) return 'png';
    if (u8.length > 3 && u8[0] === 0xFF && u8[1] === 0xD8 && u8[2] === 0xFF) return 'jpg';
    if (u8.length > 12 && u8[0] === 0x52 && u8[1] === 0x49 && u8[2] === 0x46 && u8[3] === 0x46 && u8[8] === 0x57 && u8[9] === 0x45 && u8[10] === 0x42 && u8[11] === 0x50) return 'webp';
    return '';
  }

  return { read, check, describe, imageType, sha256Hex, hex, validId, Reject, MAX_PEK, MAX_FILE, BUILTIN_IDS, OWNER_ONLY_IDS };
})();
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
