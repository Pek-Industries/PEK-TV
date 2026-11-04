import { SESSION_REFRESH_BELOW, SESSION_TTL } from './config.js';
import { randomToken, sha256Hex } from './crypto.js';

// ---------------------------------------------------------------- sessions
export async function startSession(db, userId, now, devRef) {
    const token = randomToken();
    await db.prepare('INSERT INTO sessions (token_hash, user_id, created, expires, dev_ref) VALUES (?, ?, ?, ?, ?)')
        .bind(await sha256Hex('hesper:session:' + token), userId, now, now + SESSION_TTL, devRef || null).run();
    // tidy up: expired sessions, expired throttle rows, expired reset codes
    await db.batch([
        db.prepare('DELETE FROM sessions WHERE expires < ?').bind(now),
        db.prepare('DELETE FROM throttle WHERE reset_at < ?').bind(now),
        db.prepare('DELETE FROM resets WHERE expires < ?').bind(now),
        db.prepare('DELETE FROM verifs WHERE expires < ?').bind(now),
        db.prepare('DELETE FROM reject_tokens WHERE expires < ?').bind(now),
        // half-finished plugin uploads (never committed) older than a day
        db.prepare('DELETE FROM plugin_chunks WHERE created < ? AND NOT EXISTS (SELECT 1 FROM plugins p WHERE p.acct = plugin_chunks.acct AND p.id = plugin_chunks.id AND p.fp = plugin_chunks.fp)').bind(now - 24 * 3600 * 1000)
    ]);
    return token;
}

export async function sessionFor(request, db, now) {
    const h = request.headers.get('Authorization') || '';
    const m = /^Bearer\s+(\S+)$/i.exec(h);
    if (!m || m[1].length < 20 || m[1].length > 100) return null;
    const hash = await sha256Hex('hesper:session:' + m[1]);
    const row = await db.prepare('SELECT user_id, expires FROM sessions WHERE token_hash = ?').bind(hash).first();
    if (!row || row.expires < now) return null;
    if (row.expires - now < SESSION_REFRESH_BELOW) {
        await db.prepare('UPDATE sessions SET expires = ? WHERE token_hash = ?').bind(now + SESSION_TTL, hash).run();
    }
    return { userId: row.user_id, tokenHash: hash };
}
