import { planOf } from './account.js';
import { DEVICE_TTL, json } from './config.js';
import { randomToken, sha256Hex, sixDigits } from './crypto.js';
import { clientIp, limited, readJson } from './input.js';
import { deviceFrom, emailReady, geoFrom, makeRejectUrl, sendDeviceNotice, whenText } from './mail.js';
import { startSession } from './sessions.js';

// ---------------------------------------------------------------- TV link login (6-digit code + QR)
// 1. The TV asks /v1/device/start for a code and keeps the secret `poll` value; it shows the code (and a QR with it) on screen.
// 2. The person opens the website's verify page signed in, sees which device it is (/v1/device/info) and approves it (/v1/device/approve).
// 3. The TV polls /v1/device/poll with its secret; once approved it gets a normal session token (made at that moment, never stored).
// The code alone gives nothing: it only works together with a signed-in account approving it, for DEVICE_TTL.
export async function handleDeviceStart(request, env) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    if (await limited(db, 'device:start:' + clientIp(request), 20, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    await db.prepare('DELETE FROM device_links WHERE expires < ?').bind(now).run();
    const dev = deviceFrom(body.device || body, now, request) || { type: 'Device', name: 'Unnamed device', ip: geoFrom(request).ip, location: geoFrom(request).location };
    const poll = randomToken();
    const pollHash = await sha256Hex('hesper:device:poll:' + poll);
    for (let i = 0; i < 6; i++) {
        const code = sixDigits();
        try {
            await db.prepare('INSERT INTO device_links (poll_hash, code_hash, dtype, dname, created, expires, user_id, ip, loc) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)')
                .bind(pollHash, await sha256Hex('hesper:device:code:' + code), dev.type, dev.name, now, now + DEVICE_TTL, dev.ip || '', dev.location || '').run();
        } catch (e) { continue; }   // another live TV has this code: draw another one
        return json({ ok: true, poll, code, expiresIn: Math.floor(DEVICE_TTL / 1000), interval: 3 });
    }
    return json({ error: 'server_busy' }, 503);
}

export async function handleDevicePoll(request, env) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const poll = typeof body.poll === 'string' ? body.poll : '';
    if (poll.length < 20 || poll.length > 100) return json({ error: 'expired' }, 410);
    const pollHash = await sha256Hex('hesper:device:poll:' + poll);
    if (await limited(db, 'device:poll:' + pollHash, 400, DEVICE_TTL, now)) return json({ error: 'rate_limited' }, 429);
    const row = await db.prepare('SELECT user_id, expires FROM device_links WHERE poll_hash = ?').bind(pollHash).first();
    if (!row || row.expires < now) return json({ error: 'expired' }, 410);
    if (!row.user_id) return json({ ok: true, status: 'pending' });
    // take the approval exactly once: only the call that deletes the row gets the session
    const del = await db.prepare('DELETE FROM device_links WHERE poll_hash = ? AND user_id IS NOT NULL').bind(pollHash).run();
    if (!del.meta || del.meta.changes !== 1) return json({ ok: true, status: 'pending' });
    const user = await db.prepare('SELECT email, username FROM users WHERE id = ?').bind(row.user_id).first();
    if (!user) return json({ error: 'expired' }, 410);
    return json(Object.assign({ ok: true, status: 'approved', token: await startSession(db, row.user_id, now, pollHash), email: user.email, username: user.username || '' }, await planOf(db, row.user_id, now)));
}

// Finds the waiting TV for a typed / scanned code. Wrong codes are counted so the 6 digits can't be guessed.
export async function deviceByCode(request, env, userId, now) {
    const { body, err } = await readJson(request); if (err) return { err };
    const db = env.DB;
    const code = String(body.code == null ? '' : body.code).replace(/\D/g, '');
    const userKey = 'device:miss:' + userId, ipKey = 'device:missip:' + clientIp(request);
    for (const [k, max] of [[userKey, 10], [ipKey, 30]]) {
        const lim = await db.prepare('SELECT n, reset_at FROM throttle WHERE k = ?').bind(k).first();
        if (lim && lim.reset_at > now && lim.n >= max) return { err: json({ error: 'rate_limited' }, 429) };
    }
    const row = code.length === 6
        ? await db.prepare('SELECT poll_hash, dtype, dname, created, expires, user_id, ip, loc FROM device_links WHERE code_hash = ? AND expires > ?')
            .bind(await sha256Hex('hesper:device:code:' + code), now).first()
        : null;
    if (!row) {
        await limited(db, userKey, 10, 15 * 60 * 1000, now);
        await limited(db, ipKey, 30, 15 * 60 * 1000, now);
        return { err: json({ error: 'bad_code' }, 404) };
    }
    return { row };
}

// Shows which TV the code belongs to, so the person can check it before approving. Changes nothing.
export async function handleDeviceInfo(request, env, userId) {
    const now = Date.now();
    const found = await deviceByCode(request, env, userId, now); if (found.err) return found.err;
    const row = found.row;
    const user = await env.DB.prepare('SELECT email FROM users WHERE id = ?').bind(userId).first();
    return json({ ok: true, device: { type: row.dtype, name: row.dname, ip: row.ip || '', location: row.loc || '' }, created: row.created, expires: row.expires, done: !!row.user_id, email: user ? user.email : '' });
}

export async function handleDeviceApprove(request, env, userId) {
    const db = env.DB, now = Date.now();
    const found = await deviceByCode(request, env, userId, now); if (found.err) return found.err;
    const row = found.row;
    if (row.user_id) return json(row.user_id === userId ? { ok: true, done: true } : { error: 'already_linked' }, row.user_id === userId ? 200 : 409);
    const upd = await db.prepare('UPDATE device_links SET user_id = ? WHERE poll_hash = ? AND user_id IS NULL').bind(userId, row.poll_hash).run();
    if (!upd.meta || upd.meta.changes !== 1) return json({ error: 'already_linked' }, 409);
    // tell the owner (best effort: the TV is linked either way)
    const user = await db.prepare('SELECT email FROM users WHERE id = ?').bind(userId).first();
    if (user && emailReady(env)) {
        try {
            const rejectUrl = await makeRejectUrl(env, db, userId, 'device', row.poll_hash, now);
            await sendDeviceNotice(env, user.email, { type: row.dtype, name: row.dname, ip: row.ip || '', location: row.loc || '', when: whenText(now, request) }, rejectUrl);
        }
        catch (e) { console.error('Brevo request error', String(e)); }
    }
    return json({ ok: true, device: { type: row.dtype, name: row.dname }, email: user ? user.email : '' });
}

// "Wasn't you?" on the approve page: the signed-in person throws away a waiting (or just approved, not yet collected) TV link.
export async function handleDeviceReject(request, env, userId) {
    const db = env.DB, now = Date.now();
    const found = await deviceByCode(request, env, userId, now); if (found.err) return found.err;
    const row = found.row;
    if (row.user_id && row.user_id !== userId) return json({ error: 'already_linked' }, 409);
    await db.batch([
        db.prepare('DELETE FROM device_links WHERE poll_hash = ?').bind(row.poll_hash),
        db.prepare('DELETE FROM sessions WHERE dev_ref = ? AND user_id = ?').bind(row.poll_hash, userId)
    ]);
    return json({ ok: true });
}

// The one-time link from an email (public: the token is the proof, and it only ever makes things safer).
//   'device': the TV is unlinked and, if it already collected its session, that one session is deleted.
//   'login' : the waiting sign-in code is deleted, and sessions made since the code was sent are signed out.
export async function handleRejectToken(request, env) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    if (await limited(db, 'reject:ip:' + clientIp(request), 20, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    const token = typeof body.token === 'string' ? body.token : '';
    if (token.length < 20 || token.length > 100) return json({ error: 'bad_reject' }, 404);
    const hash = await sha256Hex('hesper:reject:' + token);
    const row = await db.prepare('SELECT user_id, kind, ref, created FROM reject_tokens WHERE hash = ? AND expires > ?').bind(hash, now).first();
    if (!row) return json({ error: 'bad_reject' }, 404);
    let signedOut = 0;
    if (row.kind === 'device') {
        const r = await db.prepare('DELETE FROM sessions WHERE dev_ref = ? AND user_id = ?').bind(row.ref, row.user_id).run();
        signedOut = (r.meta && r.meta.changes) || 0;
        await db.prepare('DELETE FROM device_links WHERE poll_hash = ?').bind(row.ref).run();
    } else {
        await db.prepare('DELETE FROM verifs WHERE user_id = ?').bind(row.user_id).run();
        const r = await db.prepare('DELETE FROM sessions WHERE user_id = ? AND created >= ?').bind(row.user_id, row.created).run();
        signedOut = (r.meta && r.meta.changes) || 0;
    }
    await db.prepare('DELETE FROM reject_tokens WHERE hash = ?').bind(hash).run();
    return json({ ok: true, kind: row.kind, signedOut });
}
