import { json } from './config.js';
import { clientIp, limited, readJson } from './input.js';

// ---------------------------------------------------------------- subtitles (one shared OpenSubtitles.com account)
// Everyone's app asks this worker, so nobody needs their own OpenSubtitles account. The worker holds the key.
//   POST /v1/subs/search  { title, year?, season?, episode?, lang?, file? }  -> { ok, results: [{id,name,lang,title,downloads,hi,ai,trusted,score}] }
//   POST /v1/subs/get     { id }                                             -> { ok, text, cached }   (SubRip, UTF-8)
// Search costs nothing against OpenSubtitles' daily download limit. A download does, so:
//   - every downloaded subtitle is kept in D1 (table subs_cache) and served to all later users for free;
//   - downloads are counted per day for the whole service (SUBS_DAILY_LIMIT, default 18 of the free 20)
//     and per IP address (SUBS_IP_DAILY_LIMIT, default 8), so one person cannot use everybody's quota.
// Secrets: OPENSUBTITLES_API_KEY, OPENSUBTITLES_USER, OPENSUBTITLES_PASS  (Text: SUBS_DAILY_LIMIT, SUBS_IP_DAILY_LIMIT optional)
export const OS_HOST = 'https://api.opensubtitles.com';
export const OS_UA = 'PEK TV v1.0';
export const SUBS_CACHE_DAYS = 90;
export const SUBS_MAX_BYTES = 2 * 1024 * 1024;
let osSession = null;   // { token, base, exp } kept while this worker instance lives

export function subsReady(env) { return !!(env.OPENSUBTITLES_API_KEY && env.OPENSUBTITLES_USER && env.OPENSUBTITLES_PASS); }
export function osHeaders(env, extra) {
    return Object.assign({ 'Api-Key': env.OPENSUBTITLES_API_KEY, 'User-Agent': OS_UA, 'Accept': 'application/json' }, extra || {});
}
export function wordSet(s) {
    const out = new Set();
    String(s || '').toLowerCase().split(/[^a-z0-9]+/).forEach(w => { if (w.length > 1) out.add(w); });
    return out;
}
export function goodLang(l) { return typeof l === 'string' && /^[a-z]{2}(-[a-z]{2})?(,[a-z]{2}(-[a-z]{2})?){0,4}$/i.test(l); }

export async function osLogin(env, force) {
    const now = Date.now();
    if (!force && osSession && osSession.exp > now) return osSession;
    const r = await fetch(OS_HOST + '/api/v1/login', {
        method: 'POST',
        headers: osHeaders(env, { 'Content-Type': 'application/json' }),
        body: JSON.stringify({ username: env.OPENSUBTITLES_USER, password: env.OPENSUBTITLES_PASS })
    });
    if (!r.ok) { osSession = null; throw new Error('os_login_' + r.status); }
    const j = await r.json();
    if (!j.token) throw new Error('os_login_no_token');
    let base = String(j.base_url || 'api.opensubtitles.com').replace(/^https?:\/\//, '').replace(/\/+$/, '');
    if (!/^[a-z0-9.-]+$/i.test(base)) base = 'api.opensubtitles.com';
    osSession = { token: j.token, base: 'https://' + base, exp: now + 20 * 3600 * 1000 };
    return osSession;
}

export async function handleSubsSearch(request, env) {
    if (!subsReady(env)) return json({ ok: false, error: 'Subtitles are not set up on the server yet.' }, 503);
    const { body, err } = await readJson(request);
    if (err) return err;
    const db = env.DB, now = Date.now();
    if (await limited(db, 'subs:search:ip:' + clientIp(request), 120, 3600 * 1000, now)) return json({ ok: false, error: 'Too many subtitle searches. Try again in a little while.' }, 429);
    const title = typeof body.title === 'string' ? body.title.trim().slice(0, 200) : '';
    if (!title) return json({ ok: false, error: 'No title to search for.' }, 400);
    const year = Number(body.year) | 0, season = Number(body.season) | 0, episode = Number(body.episode) | 0;
    const lang = goodLang(body.lang) ? String(body.lang).toLowerCase() : 'en';
    const file = typeof body.file === 'string' ? body.file.slice(0, 300) : '';
    const isEp = season > 0 && episode > 0;

    // OpenSubtitles wants lower-case parameter names in alphabetical order
    const p = [];
    if (isEp) p.push(['episode_number', episode]);
    p.push(['languages', lang], ['order_by', 'download_count'], ['order_direction', 'desc'], ['query', title.toLowerCase()]);
    if (isEp) p.push(['season_number', season]);
    p.push(['type', isEp ? 'episode' : 'movie']);
    if (!isEp && year > 1800 && year < 2200) p.push(['year', year]);
    const qs = p.map(kv => kv[0] + '=' + encodeURIComponent(kv[1])).join('&');

    // the same title is searched by many people: keep the raw answer for 6 hours (search is free, this just saves calls)
    const cacheKey = new Request('https://subs-cache.invalid/search?' + qs);
    let raw = null;
    const hit = await caches.default.match(cacheKey);
    if (hit) raw = await hit.json();
    if (!raw) {
        const r = await fetch(OS_HOST + '/api/v1/subtitles?' + qs, { headers: osHeaders(env) });
        if (r.status === 429) return json({ ok: false, error: 'OpenSubtitles is busy. Try again in a minute.' }, 429);
        if (!r.ok) return json({ ok: false, error: 'OpenSubtitles answered HTTP ' + r.status + '.' }, 502);
        raw = await r.json();
        await caches.default.put(cacheKey, new Response(JSON.stringify(raw), { headers: { 'Cache-Control': 'max-age=21600', 'Content-Type': 'application/json' } }));
    }

    const want = wordSet(file || title), wantLower = file.toLowerCase();
    const list = [];
    for (const item of (raw.data || [])) {
        const at = item && item.attributes;
        const f = at && at.files && at.files[0];
        if (!f || !f.file_id) continue;
        const name = at.release || f.file_name || '';
        const downloads = Number(at.download_count) || 0;
        const ai = !!(at.ai_translated || at.machine_translated), hi = !!at.hearing_impaired, trusted = !!at.from_trusted;
        let shared = 0;
        wordSet(name).forEach(w => { if (want.has(w)) shared++; });
        let score = shared * 12;
        if (file && name.toLowerCase() === wantLower) score += 60;
        score += Math.min(40, downloads / 500);
        if (trusted) score += 15;
        if (ai) score -= 40;
        if (hi) score -= 8;
        list.push({ id: String(f.file_id), name: name, lang: at.language || '', title: (at.feature_details && at.feature_details.title) || '', downloads: downloads, hi: hi, ai: ai, trusted: trusted, score: Math.round(score) });
    }
    list.sort((a, b) => b.score - a.score);
    return json({ ok: true, results: list.slice(0, 25) });
}

export function decodeSubtitle(buf) {
    let text;
    try { text = new TextDecoder('utf-8', { fatal: true }).decode(buf); }
    catch (e) { text = new TextDecoder('windows-1252').decode(buf); }   // old files are often Windows-1252
    return text.replace(/^\uFEFF/, '');
}

export async function handleSubsGet(request, env) {
    if (!subsReady(env)) return json({ ok: false, error: 'Subtitles are not set up on the server yet.' }, 503);
    const { body, err } = await readJson(request);
    if (err) return err;
    const db = env.DB, now = Date.now();
    const id = typeof body.id === 'string' || typeof body.id === 'number' ? String(body.id) : '';
    if (!/^\d{1,12}$/.test(id)) return json({ ok: false, error: 'Bad subtitle id.' }, 400);
    if (await limited(db, 'subs:get:ip:' + clientIp(request), 200, 3600 * 1000, now)) return json({ ok: false, error: 'Too many requests. Try again in a little while.' }, 429);

    // 1) already downloaded by anyone: free
    const row = await db.prepare('SELECT text FROM subs_cache WHERE id = ?').bind(id).first();
    if (row && row.text) return json({ ok: true, text: row.text, cached: true });

    // 2) a real download: counted against the service's day and this address's day
    const dayLimit = Math.max(1, Number(env.SUBS_DAILY_LIMIT) || 18);
    const ipLimit = Math.max(1, Number(env.SUBS_IP_DAILY_LIMIT) || 8);
    const DAY = 24 * 3600 * 1000;
    if (await limited(db, 'subs:dl:ip:' + clientIp(request), ipLimit, DAY, now)) return json({ ok: false, error: 'You have reached today\'s subtitle download limit. It resets tomorrow.' }, 429);
    if (await limited(db, 'subs:dl:all', dayLimit, DAY, now)) return json({ ok: false, error: 'Subtitle downloads are used up for today. Try again tomorrow.' }, 429);

    let text = '';
    try {
        for (let attempt = 0; attempt < 2; attempt++) {
            const s = await osLogin(env, attempt > 0);
            const r = await fetch(s.base + '/api/v1/download', {
                method: 'POST',
                headers: osHeaders(env, { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + s.token }),
                body: JSON.stringify({ file_id: Number(id), sub_format: 'srt' })
            });
            if (r.status === 401 && attempt === 0) continue;                       // token went stale: sign in again once
            if (r.status === 406) {                                                  // OpenSubtitles says the real limit is reached: stop for everybody until tomorrow
                await db.prepare('UPDATE throttle SET n = ? WHERE k = ?').bind(dayLimit, 'subs:dl:all').run();
                return json({ ok: false, error: 'Subtitle downloads are used up for today. Try again tomorrow.' }, 429);
            }
            if (r.status === 429) return json({ ok: false, error: 'OpenSubtitles is busy. Try again in a minute.' }, 429);
            if (!r.ok) return json({ ok: false, error: 'OpenSubtitles answered HTTP ' + r.status + '.' }, 502);
            const j = await r.json();
            let link;
            try { link = new URL(j.link); } catch (e) { return json({ ok: false, error: 'No download link came back.' }, 502); }
            const h = link.hostname.toLowerCase();
            if (link.protocol !== 'https:' || !(h === 'opensubtitles.org' || h === 'opensubtitles.com' || h.endsWith('.opensubtitles.org') || h.endsWith('.opensubtitles.com'))) {
                return json({ ok: false, error: 'Unexpected download address.' }, 502);
            }
            const d = await fetch(link.href, { headers: { 'User-Agent': OS_UA } });
            if (!d.ok) return json({ ok: false, error: 'Could not download that subtitle.' }, 502);
            const buf = await d.arrayBuffer();
            if (!buf.byteLength || buf.byteLength > SUBS_MAX_BYTES) return json({ ok: false, error: 'That subtitle file is empty or too large.' }, 502);
            text = decodeSubtitle(buf);
            break;
        }
    } catch (e) {
        return json({ ok: false, error: 'Could not reach OpenSubtitles.' }, 502);
    }
    if (!text) return json({ ok: false, error: 'No subtitle came back.' }, 502);

    await db.prepare('INSERT OR REPLACE INTO subs_cache (id, text, created) VALUES (?, ?, ?)').bind(id, text, now).run();
    // tidy up now and then: old entries go
    if (Math.random() < 0.05) await db.prepare('DELETE FROM subs_cache WHERE created < ?').bind(now - SUBS_CACHE_DAYS * DAY).run();
    return json({ ok: true, text: text, cached: false });
}
