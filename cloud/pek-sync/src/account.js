import { DAY_MS, deleteMs, GRACE_MS, json } from './config.js';
import { cleanUsername, readJson } from './input.js';
import { likeProfiles } from './sync.js';

// ---------------------------------------------------------------- plans
// Same rules as cloud/billing-worker.js (that worker is the only one that ever changes a plan).
export function isEntitled(u, now) {
    if (!u) return false;
    if (u.plan === 'grandfathered' || u.plan === 'lifetime') return true;
    return (u.plan === 'monthly' || u.plan === 'yearly') && Number(u.plan_until) > now;
}
// Where a lapsed plan is: 'grace' (renewal missed, PEK Cloud still on until graceEnds), 'deletion' (backup is off; the account and its data are
// deleted at deleteAt unless a plan is bought before then) or 'none'. Accounts that never paid, lifetime and grandfathered never lapse.
export function lapseOf(u, now, env) {
    const paid = u.plan === 'monthly' || u.plan === 'yearly';
    const until = Number(u.plan_until) || 0;
    if (paid && !u.plan_cancel && until > now && until - GRACE_MS <= now) return { state: 'grace', graceEnds: until, deleteAt: 0 };
    if (paid && until > 0 && until <= now) return { state: 'deletion', graceEnds: until, deleteAt: Number(u.delete_at) || Math.max(until + deleteMs(env), now + 7 * DAY_MS) };
    if (u.plan === 'free' && Number(u.delete_at) > 0) return { state: 'deletion', graceEnds: 0, deleteAt: Number(u.delete_at) };
    return { state: 'none', graceEnds: 0, deleteAt: 0 };
}
export async function planOf(db, userId, now, env) {
    const u = await db.prepare('SELECT plan, plan_until, plan_cancel, plan_since, delete_at FROM users WHERE id = ?').bind(userId).first();
    if (!u) return { plan: 'free', entitled: false, until: 0, cancelling: false, since: 0, lapse: { state: 'none', graceEnds: 0, deleteAt: 0 } };
    const paidPlan = u.plan === 'monthly' || u.plan === 'yearly' || u.plan === 'lifetime';
    return { plan: u.plan, entitled: isEntitled(u, now), until: (u.plan === 'monthly' || u.plan === 'yearly') ? Number(u.plan_until) : 0, cancelling: !!u.plan_cancel,
        since: paidPlan ? Number(u.plan_since) || 0 : 0, lapse: lapseOf(u, now, env) };
}

// POST /v1/account/username { username } -> { ok, username }
// Accounts made before usernames were required have none ('') and choose one here, once. After that it is fixed.
export async function handleSetUsername(request, env, userId) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB;
    const username = cleanUsername(body.username);
    if (username === null) return json({ error: 'bad_username' }, 400);
    if (!username) return json({ error: 'username_required' }, 400);
    const me = await db.prepare('SELECT username FROM users WHERE id = ?').bind(userId).first();
    if (!me) return json({ error: 'bad_session' }, 401);
    if (me.username) return json({ error: 'username_set' }, 409);
    if (await db.prepare('SELECT id FROM users WHERE username = ? COLLATE NOCASE AND id <> ?').bind(username, userId).first()) return json({ error: 'username_taken' }, 409);
    try {
        await db.prepare("UPDATE users SET username = ? WHERE id = ? AND username = ''").bind(username, userId).run();
    } catch (e) {
        return json({ error: 'username_taken' }, 409);          // lost a race with someone taking the same name
    }
    return json({ ok: true, username });
}

// GET /v1/me -> { ok, email, username, plan, entitled, until, cancelling, since, lapse: { state, graceEnds, deleteAt }, now }
export async function handleMe(env, userId) {
    const u = await env.DB.prepare('SELECT email, username FROM users WHERE id = ?').bind(userId).first();
    if (!u) return json({ error: 'bad_session' }, 401);
    return json(Object.assign({ ok: true, email: u.email, username: u.username || '', now: Date.now() }, await planOf(env.DB, userId, Date.now(), env)));
}


export async function handleExport(env, acct) {
    const user = await env.DB.prepare('SELECT email, created FROM users WHERE id = ?').bind(acct).first();
    const rows = await env.DB.prepare(
        'SELECT acct AS owner, kind, key, data, updated, deleted FROM items WHERE acct = ? OR acct LIKE ? ORDER BY updated'
    ).bind(acct, likeProfiles(acct)).all();
    const items = (rows.results || []).map(r => {
        let data = {};
        try { data = JSON.parse(r.data); } catch (e) { /* keep {} */ }
        const profile = r.owner === acct ? 'p1' : r.owner.slice(acct.length + 1);
        return { profile, kind: r.kind === 'h' ? 'history' : r.kind === 'f' ? 'favorites' : r.kind === 's' ? 'settings' : r.kind === 'k' ? 'skins' : r.kind === 'r' ? 'ratings' : 'progress', key: r.key, data, updated: r.updated, deleted: !!r.deleted };
    });
    const pr = await env.DB.prepare('SELECT id, name, color, updated, deleted, avatar, pin FROM profiles WHERE acct = ? ORDER BY updated').bind(acct).all();
    const profiles = (pr.results || []).map(r => ({ id: r.id, name: r.name, color: r.color, updated: r.updated, deleted: !!r.deleted, avatar: r.avatar || '', hasPasscode: !!r.pin }));   // the passcode hash is not exported
    const pl = await env.DB.prepare('SELECT id, name, version, size, updated, deleted FROM plugins WHERE acct = ? ORDER BY id').bind(acct).all();
    const plugins = (pl.results || []).map(r => ({ id: r.id, name: r.name, version: r.version, size: r.size, updated: r.updated, deleted: !!r.deleted }));
    return json({ exported: Date.now(), email: user ? user.email : '', profiles, items, plugins });
}

export async function handleDelete(env, acct) {
    // A renewing subscription keeps charging after the account is gone, so it has to be cancelled first (on the website).
    const pl = await env.DB.prepare('SELECT plan, plan_until, plan_cancel, stripe_sub FROM users WHERE id = ?').bind(acct).first();
    if (pl && (pl.plan === 'monthly' || pl.plan === 'yearly') && pl.stripe_sub && !pl.plan_cancel && Number(pl.plan_until) > Date.now()) return json({ error: 'cancel_subscription_first' }, 409);
    await purgeAccount(env.DB, acct, false);
    return json({ ok: true });
}

// Deletes an account and everything stored for it. tombstone = true (the daily job) first remembers the account's sessions, so a device that
// still has one is told "your account was deleted" (410) the next time it asks.
export async function purgeAccount(db, acct, tombstone) {
    if (tombstone) await db.prepare('INSERT OR IGNORE INTO gone_sessions (token_hash, deleted) SELECT token_hash, ? FROM sessions WHERE user_id = ?').bind(Date.now(), acct).run();
    await db.batch([
        db.prepare('DELETE FROM items WHERE acct = ? OR acct LIKE ?').bind(acct, likeProfiles(acct)),
        db.prepare('DELETE FROM profiles WHERE acct = ?').bind(acct),
        db.prepare('DELETE FROM plugins WHERE acct = ?').bind(acct),
        db.prepare('DELETE FROM plugin_chunks WHERE acct = ?').bind(acct),
        db.prepare('DELETE FROM sessions WHERE user_id = ?').bind(acct),
        db.prepare('DELETE FROM resets WHERE user_id = ?').bind(acct),
        db.prepare('DELETE FROM verifs WHERE user_id = ?').bind(acct),
        db.prepare('DELETE FROM reject_tokens WHERE user_id = ?').bind(acct),
        db.prepare('DELETE FROM device_links WHERE user_id = ?').bind(acct),
        db.prepare('DELETE FROM users WHERE id = ?').bind(acct)
    ]);
}
