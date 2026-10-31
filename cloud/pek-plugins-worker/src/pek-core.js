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
  const PERMISSIONS = ['storage', 'library', 'torrent', 'favorites', 'providers', 'plugins', 'watched', 'playback', 'send', 'skins', 'live', 'epg'];

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
