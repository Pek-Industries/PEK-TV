import { purgeAccount } from './account.js';
import { DAY_MS, deleteMs, GRACE_MS, NOTICE_EVERY_MS, NOTICE_SLACK_MS } from './config.js';
import { sha256Hex } from './crypto.js';
import { init } from './db.js';
import { emailReady, escHtml, postMail, webUrl } from './mail.js';

// ---------------------------------------------------------------- lapsed plans: the daily job
export async function sessionWasDeleted(request, db) {
    const m = /^Bearer\s+(\S+)$/i.exec(request.headers.get('Authorization') || '');
    if (!m || m[1].length < 20 || m[1].length > 100) return false;
    const row = await db.prepare('SELECT deleted FROM gone_sessions WHERE token_hash = ?').bind(await sha256Hex('hesper:session:' + m[1])).first();
    return !!row;
}

export function longDate(ms) { return new Intl.DateTimeFormat('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' }).format(new Date(ms)); }

// kind: 'grace' (renewal overdue; deleteAt is then the end of the grace), 'started' (the deletion period began), 'reminder' (every 3 days after that), 'deleted' (it is done)
export async function sendLifecycleMail(env, to, kind, deleteAt) {
    if (!to || !emailReady(env)) return false;
    const date = longDate(deleteAt), link = webUrl(env) + '/account';
    const daysLeft = Math.max(1, Math.ceil((Number(deleteAt) - Date.now()) / DAY_MS));
    const M = {
        started: { subject: 'Your PEK Cloud data will be deleted on ' + date, title: 'Your PEK Cloud plan has ended', lines: [
            'Cloud backup is switched off. If you do not subscribe again before ' + date + ', your account and everything stored in it (profiles, watch history, resume points and plugin backups) will be permanently deleted and cannot be recovered.',
            'Subscribing again before then turns everything back on exactly as it was.'] },
        grace: { subject: 'Your PEK Cloud payment is overdue', title: 'Payment overdue', lines: [
            'We could not collect your PEK Cloud renewal. Cloud backup stays on until ' + date + '. Please update your payment method or pay before then to keep everything on.',
            'If the plan is not paid by then, cloud backup is switched off and a countdown to deleting your account starts. You will get an email every 3 days from now until it is paid or the account is deleted.'] },
        reminder: { subject: daysLeft + (daysLeft === 1 ? ' day' : ' days') + ' left: your PEK Cloud data is deleted on ' + date, title: 'Your PEK Cloud data will be deleted on ' + date, lines: [
            'Your PEK Cloud plan has not been renewed. There ' + (daysLeft === 1 ? 'is 1 day' : 'are ' + daysLeft + ' days') + ' left: your account and everything stored in it (profiles, watch history, resume points and plugin backups) will be permanently deleted on ' + date + ' unless you subscribe again before then. Deleted data cannot be recovered.',
            'Subscribing again before then turns everything back on exactly as it was. You will get another email every 3 days until then.'] },
        deleted: { subject: 'Your PEK Cloud account was deleted', title: 'Your PEK Cloud account was deleted', lines: [
            'Your plan was not renewed before ' + date + ', so your account and all the data stored in it were permanently deleted. This cannot be undone and the data cannot be recovered.',
            'You are welcome to create a new account at any time.'] }
    }[kind];
    const text = M.title + '\n\n' + M.lines.join('\n\n') + (kind === 'deleted' ? '' : '\n\n' + (kind === 'grace' ? 'Update payment' : 'Subscribe again') + ': ' + link);
    const html = '<div style="font-family:Arial,Helvetica,sans-serif;max-width:440px;margin:0 auto;padding:24px;color:#111"><h2 style="margin:0 0 12px">' + escHtml(M.title) + '</h2>' +
        M.lines.map(l => '<p style="margin:0 0 14px;line-height:1.5">' + escHtml(l) + '</p>').join('') +
        (kind === 'deleted' ? '' : '<p style="margin:18px 0 0"><a href="' + escHtml(link) + '" style="background:#2b2420;color:#fff;text-decoration:none;padding:10px 18px;border-radius:8px;display:inline-block">' + (kind === 'grace' ? 'Update payment' : 'Subscribe again') + '</a></p>') + '</div>';
    return postMail(env, to, M.subject, text, html);
}

// Runs once a day. 1) paid plans whose grace ran out start their deletion period; 2) emails, one every 3 days (grace, then the countdown); 3) accounts whose period is over
// are deleted and get the final "deleted" email.
// Only accounts that had a paid renewing plan are ever touched (delete_at is only set for them); free accounts that never paid, lifetime and
// grandfathered accounts are never deleted here, and a plan bought in time clears delete_at (billing-worker.js).
export async function runLifecycle(env) {
    if (!env.DB) return;
    const db = env.DB;
    await init(db);
    const now = Date.now(), del = deleteMs(env);
    // delete_at = the end of the grace plus the deletion period, but never less than 7 days from now: an account that lapsed long before this job existed still gets a warning first.
    await db.prepare("UPDATE users SET delete_at = MAX(plan_until + ?, ?), notice_stage = 0 WHERE plan IN ('monthly','yearly') AND plan_until > 0 AND plan_until <= ? AND delete_at = 0").bind(del, now + 7 * DAY_MS, now).run();
    // Grace: a renewal was missed but PEK Cloud is still on (see lapseOf). One reminder email every 3 days until it is paid or the grace ends.
    const overdue = await db.prepare("SELECT id, email, plan_until FROM users WHERE plan IN ('monthly','yearly') AND plan_cancel = 0 AND plan_until > ? AND plan_until - ? <= ? AND grace_mail_at <= ? LIMIT 500").bind(now, GRACE_MS, now, now - NOTICE_EVERY_MS + NOTICE_SLACK_MS).all();
    for (const u of (overdue.results || [])) {
        if (await sendLifecycleMail(env, u.email, 'grace', u.plan_until)) await db.prepare('UPDATE users SET grace_mail_at = ? WHERE id = ?').bind(now, u.id).run();
    }
    const waiting = await db.prepare("SELECT id, email, delete_at, notice_stage, notice_at FROM users WHERE delete_at > ? AND plan NOT IN ('lifetime','grandfathered') LIMIT 500").bind(now).all();
    for (const u of (waiting.results || [])) {
        const left = Number(u.delete_at) - now;
        if (Number(u.notice_stage) < 1) {
            if (await sendLifecycleMail(env, u.email, 'started', u.delete_at) || !emailReady(env)) await db.prepare('UPDATE users SET notice_stage = 1, notice_at = ? WHERE id = ?').bind(now, u.id).run();
        } else if (left >= DAY_MS && now - Number(u.notice_at) >= NOTICE_EVERY_MS - NOTICE_SLACK_MS) {
            // every 3 days until the end; none in the last day (the "deleted" email follows right after)
            if (await sendLifecycleMail(env, u.email, 'reminder', u.delete_at) || !emailReady(env)) await db.prepare('UPDATE users SET notice_stage = notice_stage + 1, notice_at = ? WHERE id = ?').bind(now, u.id).run();
        }
    }
    const due = await db.prepare("SELECT id FROM users WHERE delete_at > 0 AND delete_at <= ? AND plan NOT IN ('lifetime','grandfathered') AND NOT (plan IN ('monthly','yearly') AND plan_until > ?) LIMIT 25").bind(now, now).all();
    for (const r of (due.results || [])) {
        const u = await db.prepare('SELECT id, email, plan, plan_until, delete_at FROM users WHERE id = ?').bind(r.id).first();      // look again right before deleting
        if (!u || Number(u.delete_at) <= 0 || Number(u.delete_at) > Date.now()) continue;
        if (u.plan === 'lifetime' || u.plan === 'grandfathered' || ((u.plan === 'monthly' || u.plan === 'yearly') && Number(u.plan_until) > Date.now())) continue;
        await sendLifecycleMail(env, u.email, 'deleted', u.delete_at);
        await purgeAccount(db, u.id, true);
        console.log('deleted a lapsed account', u.id);
    }
    await db.prepare('DELETE FROM gone_sessions WHERE deleted < ?').bind(now - 60 * DAY_MS).run();
}
