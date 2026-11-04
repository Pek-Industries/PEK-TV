import { planOf } from './account.js';
import { json, MAX_PASSWORD, RESEND_GAP, RESET_MAX_TRIES, RESET_TTL } from './config.js';
import { burnTime, checkPassword, hashPassword, randomHex, sameString, sha256Hex, sixDigits } from './crypto.js';
import { cleanEmail, cleanUsername, clearLimit, clientIp, goodPassword, limited, readJson } from './input.js';
import { holdInvite, inviteHash, inviteOnly, normInvite, useInvite } from './invites.js';
import { deviceFrom, emailReady, issueLoginCode, issueVerification, sendCodeEmail } from './mail.js';
import { startSession } from './sessions.js';

// ---------------------------------------------------------------- auth handlers
export async function handleSignup(request, env) {
    if (!emailReady(env)) return json({ error: 'email_not_configured' }, 500);
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const email = cleanEmail(body.email);
    if (!email) return json({ error: 'bad_email' }, 400);
    if (!goodPassword(body.password)) return json({ error: 'weak_password' }, 400);
    if (await limited(db, 'signup:ip:' + clientIp(request), 10, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);

    const existing = await db.prepare('SELECT id, verified, gf FROM users WHERE email = ?').bind(email).first();
    if (existing && existing.verified) return json({ error: 'email_taken' }, 409);

    // Username (required for new accounts): checked before an invite is held, so a taken name never ties up a code.
    const username = cleanUsername(body.username);
    if (username === null) return json({ error: 'bad_username' }, 400);
    if (!username) return json({ error: 'username_required' }, 400);   // a username is required for every new account (3 to 20 characters)
    if (username && await db.prepare('SELECT id FROM users WHERE username = ? COLLATE NOCASE AND id <> ?').bind(username, existing ? existing.id : '').first()) return json({ error: 'username_taken' }, 409);

    // Invite-only: a new address (or one left unconfirmed since the switch) needs an unused code. Accounts that already
    // existed before the switch (gf = 1) never do, and sign-in / password reset never come through here.
    const userId = existing ? existing.id : randomHex(16);
    if (inviteOnly(env) && !(existing && existing.gf)) {
        if (await limited(db, 'invite:ip:' + clientIp(request), 20, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
        if (!normInvite(body.invite)) return json({ error: 'invite_required' }, 403);
        const hash = await inviteHash(body.invite);
        if (!hash || !(await holdInvite(db, hash, userId, now))) return json({ error: 'bad_invite' }, 403);
    }

    const pw = await hashPassword(body.password);
    let id;
    if (existing) {
        // Someone started this sign-up but never verified. The newest attempt takes it over, so nobody can
        // lock a real owner out of their own address by registering it first.
        id = existing.id;
        await db.prepare('UPDATE users SET pw = ?, created = ?, username = ? WHERE id = ?').bind(pw, now, username, id).run();
    } else {
        id = userId;
        try {
            await db.prepare("INSERT INTO users (id, email, pw, created, last_seen, verified, gf, username, plan) VALUES (?, ?, ?, ?, ?, 0, 0, ?, 'free')")
                .bind(id, email, pw, now, now, username).run();
        } catch (e) {
            await db.prepare('UPDATE invites SET reserved_by = NULL, reserved_until = 0 WHERE reserved_by = ? AND used_by IS NULL').bind(userId).run();   // give the code back
            if (username && await db.prepare('SELECT id FROM users WHERE username = ? COLLATE NOCASE').bind(username).first()) return json({ error: 'username_taken' }, 409);
            return json({ error: 'email_taken' }, 409);     // lost a race with a second sign-up
        }
    }
    if (!(await issueVerification(env, db, id, email, now))) return json({ error: 'rate_limited' }, 429);
    return json({ ok: true, needsVerify: true, email });
}

export async function handleVerify(request, env) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const email = cleanEmail(body.email);
    const code = String(body.code == null ? '' : body.code).replace(/\D/g, '');
    if (!email || code.length !== 6) return json({ error: 'bad_code' }, 400);
    if (await limited(db, 'verify:ip:' + clientIp(request), 30, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);

    const user = await db.prepare('SELECT id, verified, gf, username FROM users WHERE email = ?').bind(email).first();
    const row = user ? await db.prepare('SELECT code_hash, expires, tries FROM verifs WHERE user_id = ?').bind(user.id).first() : null;
    if (!user || !row || row.expires < now || row.tries >= RESET_MAX_TRIES) return json({ error: 'bad_code' }, 400);

    if (!sameString(await sha256Hex('hesper:verify:' + user.id + ':' + code), row.code_hash)) {
        await db.prepare('UPDATE verifs SET tries = tries + 1 WHERE user_id = ?').bind(user.id).run();
        return json({ error: 'bad_code' }, 400);
    }
    if (!(await useInvite(env, db, user, now))) return json({ error: 'bad_invite' }, 403);   // sign-up only: the invite is burned here
    await db.batch([
        db.prepare('UPDATE users SET verified = 1, last_seen = ? WHERE id = ?').bind(now, user.id),
        db.prepare('DELETE FROM verifs WHERE user_id = ?').bind(user.id)
    ]);
    return json(Object.assign({ ok: true, token: await startSession(db, user.id, now), email, username: user.username || '' }, await planOf(db, user.id, now)));
}

// Sends a new code: to an unverified account, or to a sign-in that is waiting for its code. Always answers ok.
export async function handleResend(request, env) {
    if (!emailReady(env)) return json({ error: 'email_not_configured' }, 500);
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const email = cleanEmail(body.email);
    if (!email) return json({ error: 'bad_email' }, 400);
    if (await limited(db, 'resend:ip:' + clientIp(request), 20, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    // One new code per address every 30 seconds (the same for every address, so it tells nobody whether an account exists).
    if (await limited(db, 'resend:gap:' + email, 1, RESEND_GAP, now)) {
        const gap = await db.prepare('SELECT reset_at FROM throttle WHERE k = ?').bind('resend:gap:' + email).first();
        const retryAfter = Math.min(RESEND_GAP / 1000, Math.max(1, Math.ceil(((gap ? gap.reset_at : now) - now) / 1000)));
        return json({ error: 'rate_limited', retryAfter }, 429);   // the app and the site count down this many seconds
    }
    const user = await db.prepare('SELECT id, verified FROM users WHERE email = ?').bind(email).first();
    // The per-hour code limits used to stop a resend silently while the app said "a new code is on its way": say so now.
    if (user && !user.verified) {
        if (!(await issueVerification(env, db, user.id, email, now))) return json({ error: 'rate_limited' }, 429);
    }
    else if (user) {
        // A confirmed account: only while a sign-in is waiting for its code (the password was right in the last few hours),
        // so nobody can use this to fill someone else's inbox.
        const pending = await db.prepare('SELECT expires FROM verifs WHERE user_id = ?').bind(user.id).first();
        if (pending && pending.expires + 2 * 3600 * 1000 > now) {
            const sent = await issueLoginCode(env, db, user.id, email, now, deviceFrom(body.device, now, request));
            if (sent === 'limited') return json({ error: 'rate_limited' }, 429);
            if (sent === 'failed') return json({ error: 'email_failed' }, 502);
        }
    }
    return json({ ok: true });
}

export async function handleLogin(request, env) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const email = cleanEmail(body.email);
    const password = typeof body.password === 'string' ? body.password.slice(0, MAX_PASSWORD) : '';
    if (!email || !password) return json({ error: 'bad_credentials' }, 401);

    const ipKey = 'login:ip:' + clientIp(request), mailKey = 'login:mail:' + email;
    if (await limited(db, ipKey, 30, 15 * 60 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    const row = await db.prepare('SELECT id, pw, verified FROM users WHERE email = ?').bind(email).first();
    // check the per-email limit without counting yet; failures are counted below
    const lim = await db.prepare('SELECT n, reset_at FROM throttle WHERE k = ?').bind(mailKey).first();
    if (lim && lim.reset_at > now && lim.n >= 8) return json({ error: 'rate_limited' }, 429);

    let ok = false;
    if (row) ok = await checkPassword(password, row.pw); else await burnTime(password);
    if (!ok) {
        await limited(db, mailKey, 8, 15 * 60 * 1000, now);
        return json({ error: 'bad_credentials' }, 401);
    }
    await clearLimit(db, mailKey);
    if (!row.verified) {
        // right password, but the email was never confirmed: send a fresh code and let the app ask for it
        if (emailReady(env)) await issueVerification(env, db, row.id, email, now);
        return json({ error: 'email_not_verified' }, 403);
    }
    // Right password: now prove it is you with a code from the email. No session until the code is entered.
    if (!emailReady(env)) return json({ error: 'email_not_configured' }, 500);
    const sent = await issueLoginCode(env, db, row.id, email, now, deviceFrom(body.device, now, request));
    if (sent === 'limited') return json({ error: 'rate_limited' }, 429);
    if (sent === 'failed') return json({ error: 'email_failed' }, 502);
    return json({ ok: true, needsVerify: true, email });
}

export async function handleForgot(request, env) {
    if (!emailReady(env)) return json({ error: 'email_not_configured' }, 500);
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const email = cleanEmail(body.email);
    if (!email) return json({ error: 'bad_email' }, 400);
    if (await limited(db, 'forgot:ip:' + clientIp(request), 20, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    if (await limited(db, 'forgot:mail:' + email, 5, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);

    const user = await db.prepare('SELECT id FROM users WHERE email = ?').bind(email).first();
    if (user) {
        const code = sixDigits();
        await db.prepare('INSERT INTO resets (user_id, code_hash, expires, tries) VALUES (?, ?, ?, 0) ' +
            'ON CONFLICT(user_id) DO UPDATE SET code_hash = excluded.code_hash, expires = excluded.expires, tries = 0')
            .bind(user.id, await sha256Hex('hesper:reset:' + user.id + ':' + code), now + RESET_TTL).run();
        try { await sendCodeEmail(env, email, code, 'reset'); } catch (e) { console.error('Brevo request error', String(e)); }
    }
    return json({ ok: true });   // same answer whether or not the email has an account
}

export async function handleReset(request, env) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const email = cleanEmail(body.email);
    const code = String(body.code == null ? '' : body.code).replace(/\D/g, '');
    if (!email || code.length !== 6) return json({ error: 'bad_code' }, 400);
    if (!goodPassword(body.password)) return json({ error: 'weak_password' }, 400);
    if (await limited(db, 'reset:ip:' + clientIp(request), 30, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);

    const user = await db.prepare('SELECT id, verified, gf, username FROM users WHERE email = ?').bind(email).first();
    const row = user ? await db.prepare('SELECT code_hash, expires, tries FROM resets WHERE user_id = ?').bind(user.id).first() : null;
    if (!user || !row || row.expires < now || row.tries >= RESET_MAX_TRIES) return json({ error: 'bad_code' }, 400);

    const good = sameString(await sha256Hex('hesper:reset:' + user.id + ':' + code), row.code_hash);
    if (!good) {
        await db.prepare('UPDATE resets SET tries = tries + 1 WHERE user_id = ?').bind(user.id).run();
        return json({ error: 'bad_code' }, 400);
    }
    if (!(await useInvite(env, db, user, now))) return json({ error: 'bad_invite' }, 403);
    await db.batch([
        db.prepare('UPDATE users SET pw = ?, last_seen = ?, verified = 1 WHERE id = ?').bind(await hashPassword(body.password), now, user.id),   // a reset code proves the email too
        db.prepare('DELETE FROM resets WHERE user_id = ?').bind(user.id),
        db.prepare('DELETE FROM verifs WHERE user_id = ?').bind(user.id),
        db.prepare('DELETE FROM sessions WHERE user_id = ?').bind(user.id)      // everyone is signed out
    ]);
    await clearLimit(db, 'login:mail:' + email);
    return json(Object.assign({ ok: true, token: await startSession(db, user.id, now), email, username: user.username || '' }, await planOf(db, user.id, now)));
}

export async function handleLogout(env, sess) {
    await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(sess.tokenHash).run();
    return json({ ok: true });
}
