import { json, MAX_BODY, MAX_PASSWORD, MIN_PASSWORD } from './config.js';

// ---------------------------------------------------------------- input checks
export function cleanEmail(v) {
    const e = String(v == null ? '' : v).trim().toLowerCase();
    if (e.length < 5 || e.length > 254) return null;
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e)) return null;
    return e;
}
// '' = none given, null = not allowed, otherwise the cleaned name.
export function cleanUsername(v) {
    const u = String(v == null ? '' : v).trim();
    if (!u) return '';
    return /^[A-Za-z0-9][A-Za-z0-9._-]{2,19}$/.test(u) ? u : null;
}
export function goodPassword(v) {
    return typeof v === 'string' && v.length >= MIN_PASSWORD && v.length <= MAX_PASSWORD;
}
export async function readJson(request) {
    const text = await request.text();
    if (text.length > MAX_BODY) return { err: json({ error: 'too_large' }, 413) };
    try {
        const body = text ? JSON.parse(text) : {};
        if (!body || typeof body !== 'object') return { err: json({ error: 'bad_json' }, 400) };
        return { body };
    } catch (e) { return { err: json({ error: 'bad_json' }, 400) }; }
}

// ---------------------------------------------------------------- rate limiting (stored in D1)
// Returns true when the caller is OVER the limit. Counts every call it sees.
export async function limited(db, key, max, windowMs, now) {
    const row = await db.prepare('SELECT n, reset_at FROM throttle WHERE k = ?').bind(key).first();
    if (!row || row.reset_at <= now) {
        await db.prepare('INSERT INTO throttle (k, n, reset_at) VALUES (?, 1, ?) ON CONFLICT(k) DO UPDATE SET n = 1, reset_at = excluded.reset_at').bind(key, now + windowMs).run();
        return false;
    }
    if (row.n >= max) return true;
    await db.prepare('UPDATE throttle SET n = n + 1 WHERE k = ?').bind(key).run();
    return false;
}
export async function clearLimit(db, key) { await db.prepare('DELETE FROM throttle WHERE k = ?').bind(key).run(); }
export function clientIp(request) { return request.headers.get('CF-Connecting-IP') || 'unknown'; }
