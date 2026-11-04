import { INVITE_DEFAULT_DAYS, INVITE_MAX_NEW, json } from './config.js';
import { sameString, sha256Hex } from './crypto.js';
import { clientIp, limited, readJson } from './input.js';
import { inviteHash, newInviteCode } from './invites.js';

// ---------------------------------------------------------------- invite admin (only with ADMIN_KEY)
// Anyone without the key gets the same answer as for a route that does not exist.
export async function adminCheck(request, env, db, now) {
    const key = String(env.ADMIN_KEY || '');
    if (key.length < 16) return 'denied';                                   // not set up, or too short to be safe
    if (await limited(db, 'admin:ip:' + clientIp(request), 30, 15 * 60 * 1000, now)) return 'limited';
    const given = (request.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
    return sameString(await sha256Hex('pek:admin:' + given), await sha256Hex('pek:admin:' + key)) ? 'ok' : 'denied';
}

export async function handleInvites(request, env, path) {
    const db = env.DB, now = Date.now(), DAY_MS = 24 * 3600 * 1000;
    const auth = await adminCheck(request, env, db, now);
    if (auth === 'limited') return json({ error: 'rate_limited' }, 429);
    if (auth !== 'ok') return json({ error: 'not_found' }, 404);
    const { body, err } = await readJson(request); if (err) return err;

    if (path === '/v1/invites/new') {
        const count = Math.max(1, Math.min(INVITE_MAX_NEW, Math.floor(Number(body.count) || 1)));
        const days = body.days == null ? INVITE_DEFAULT_DAYS : Math.max(0, Math.min(365, Math.floor(Number(body.days) || 0)));
        const note = String(body.note == null ? '' : body.note).replace(/\s+/g, ' ').trim().slice(0, 60);
        const codes = [], stmts = [];
        for (let i = 0; i < count; i++) {
            const code = newInviteCode();
            codes.push(code);
            stmts.push(db.prepare('INSERT INTO invites (hash, created, expires, note) VALUES (?, ?, ?, ?)').bind(await inviteHash(code), now, days ? now + days * DAY_MS : 0, note));
        }
        await db.batch(stmts);
        return json({ ok: true, codes, expiresInDays: days || null });
    }
    if (path === '/v1/invites/list') {
        const rows = (await db.prepare('SELECT i.hash, i.created, i.expires, i.note, i.reserved_by, i.reserved_until, i.used_at, u.email AS used_email FROM invites i LEFT JOIN users u ON u.id = i.used_by ORDER BY i.created DESC LIMIT 200').all()).results || [];
        return json({ ok: true, invites: rows.map(r => ({
            id: r.hash.slice(0, 8),
            status: r.used_at ? 'used' : (r.expires && r.expires <= now) ? 'expired' : (r.reserved_by && r.reserved_until > now) ? 'waiting for email confirmation' : 'unused',
            note: r.note, created: new Date(r.created).toISOString(),
            expires: r.expires ? new Date(r.expires).toISOString() : null,
            usedBy: r.used_at ? (r.used_email || '(account deleted)') : null
        })) });
    }
    if (path === '/v1/invites/revoke') {
        const id = String(body.id || '').toLowerCase().replace(/[^0-9a-f]/g, '');
        if (id.length !== 8) return json({ error: 'bad_id' }, 400);
        const r = await db.prepare('DELETE FROM invites WHERE substr(hash, 1, 8) = ? AND used_at IS NULL').bind(id).run();
        return r.meta && r.meta.changes ? json({ ok: true }) : json({ error: 'not_found' }, 404);
    }
    return json({ error: 'not_found' }, 404);
}
