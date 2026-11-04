import { REJECT_TTL, VERIFY_TTL } from './config.js';
import { randomToken, sha256Hex, sixDigits } from './crypto.js';
import { clientIp, limited } from './input.js';

// ---------------------------------------------------------------- email (Brevo)
export const MAILS = {
    reset: {
        subject: 'Your PEK TV password reset code',
        title: 'Reset your PEK TV password',
        lead: 'Enter this code in the app:',
        foot: 'It works for 15 minutes. If you did not ask to reset your password, ignore this email; your password has not changed.',
        text: 'Your PEK TV password reset code is {code}\n\nIt works for 15 minutes. If you did not ask to reset your password, you can ignore this email; your password has not changed.'
    },
    login: {
        subject: 'Your PEK TV sign-in code',
        title: 'Confirm your sign-in',
        lead: 'Enter this code to finish signing in:',
        foot: 'It works for 30 minutes. If you did not just try to sign in, someone has your password: use \"Forgot password\" in the app to choose a new one.',
        text: 'Your PEK TV sign-in code is {code}\n\nIt works for 30 minutes. If you did not just try to sign in, someone has your password: use \"Forgot password\" in the app to choose a new one.'
    },
    verify: {
        subject: 'Verify your email for PEK TV',
        title: 'Verify your email',
        lead: 'Enter this code in the app to finish creating your PEK TV account:',
        foot: 'It works for 30 minutes. If you did not create a PEK TV account, ignore this email and nothing will happen.',
        text: 'Your PEK TV verification code is {code}\n\nIt works for 30 minutes. If you did not create a PEK TV account, you can ignore this email.'
    }
};

export function escHtml(v) {
    return String(v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// A device (TV, phone, browser) as the apps and the website describe it. Anything the caller sends is cut down to plain
// short text first: it ends up in an email and on the approve page, so it must never carry markup or look like a sentence.
export function cleanDeviceText(v, max) {
    return String(v == null ? '' : v).replace(/[\u0000-\u001f\u007f<>`]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max);
}
// Returns { type, name, when } or null when the caller sent no device. [request] gives the time zone of whoever is asking.
export function deviceFrom(raw, now, request) {
    if (!raw || typeof raw !== 'object') return null;
    const type = cleanDeviceText(raw.type, 24) || 'Device';
    const name = cleanDeviceText(raw.name, 60) || 'Unnamed device';
    const g = geoFrom(request);
    return { type, name, when: whenText(now, request), ip: g.ip, location: g.location };
}
// The caller's IP address and the approximate place it is in (Cloudflare's own lookup: city, region, country). Either may be empty.
export function geoFrom(request) {
    let ip = clientIp(request); if (ip === 'unknown') ip = '';
    let parts = [];
    try { const cf = request && request.cf; if (cf) parts = [cf.city, cf.region, cf.country].filter(Boolean); } catch (e) { /* none */ }
    return { ip: cleanDeviceText(ip, 45), location: cleanDeviceText(parts.join(', '), 80) };
}
export function whenText(now, request) {
    let tz = '';
    try { tz = (request && request.cf && request.cf.timezone) || ''; } catch (e) { /* none */ }
    for (const zone of [tz, 'UTC']) {
        if (zone === '' ) continue;
        try { return new Intl.DateTimeFormat('en-US', { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: zone, timeZoneName: 'short' }).format(new Date(now)); }
        catch (e) { /* unknown zone: try UTC */ }
    }
    return new Date(now).toISOString();
}

export async function postMail(env, to, subject, text, html) {
    const sender = { email: env.BREVO_SENDER_EMAIL, name: env.BREVO_SENDER_NAME || 'PEK TV' };
    const res = await fetch('https://api.brevo.com/v3/smtp/email', {
        method: 'POST',
        headers: { 'api-key': env.BREVO_API_KEY, 'accept': 'application/json', 'content-type': 'application/json' },
        body: JSON.stringify({ sender, to: [{ email: to }], subject, textContent: text, htmlContent: html })
    });
    if (!res.ok) {
        let detail = '';
        try { detail = (await res.text()).slice(0, 300); } catch (e) { /* ignore */ }
        console.error('Brevo send failed', res.status, detail);
        return false;
    }
    return true;
}

export function mailHtml(title, lead, code, device, foot, rejectUrl) {
    return '<div style="font-family:Arial,Helvetica,sans-serif;max-width:420px;margin:0 auto;padding:24px;color:#111">' +
        '<h2 style="margin:0 0 12px">' + title + '</h2>' +
        '<p style="margin:0 0 16px">' + lead + '</p>' +
        (code ? '<p style="font-size:34px;letter-spacing:8px;font-weight:bold;margin:0 0 16px">' + code + '</p>' : '') +
        (device ? '<table style="border-collapse:collapse;margin:0 0 16px;font-size:15px">' +
            '<tr><td style="padding:2px 14px 2px 0;color:#555">Device</td><td style="padding:2px 0"><b>' + escHtml(device.type) + '</b></td></tr>' +
            '<tr><td style="padding:2px 14px 2px 0;color:#555">Name</td><td style="padding:2px 0"><b>' + escHtml(device.name) + '</b></td></tr>' +
            (device.location ? '<tr><td style="padding:2px 14px 2px 0;color:#555">Location</td><td style="padding:2px 0"><b>' + escHtml(device.location) + '</b></td></tr>' : '') +
            (device.ip ? '<tr><td style="padding:2px 14px 2px 0;color:#555">IP address</td><td style="padding:2px 0"><b>' + escHtml(device.ip) + '</b></td></tr>' : '') +
            '<tr><td style="padding:2px 14px 2px 0;color:#555">Time</td><td style="padding:2px 0"><b>' + escHtml(device.when) + '</b></td></tr></table>' : '') +
        '<p style="margin:0;color:#555;font-size:14px">' + foot + '</p>' +
        (rejectUrl ? '<p style="margin:14px 0 0;font-size:12px"><a href="' + escHtml(rejectUrl) + '" style="color:#a33">Wasn\'t you? Reject this login</a></p>' : '') +
        '</div>';
}
export function deviceText(device) {
    return device ? '\nDevice: ' + device.type + '\nName: ' + device.name +
        (device.location ? '\nLocation: ' + device.location : '') + (device.ip ? '\nIP address: ' + device.ip : '') +
        '\nTime: ' + device.when + '\n' : '';
}

// [device] (optional) = where the sign-in is happening; the email then says which device, what it is called and when.
export async function sendCodeEmail(env, to, code, kind, device, rejectUrl) {
    const m = MAILS[kind];
    let text = m.text.replace('{code}', code);
    if (device) text = text.replace('\n\n', deviceText(device) + '\n');
    if (rejectUrl) text += '\n\nWasn\'t you? Reject this login: ' + rejectUrl;
    return postMail(env, to, m.subject, text, mailHtml(m.title, m.lead, code, device, m.foot, rejectUrl));
}

// Tells the owner that a device was just signed in with the TV link (QR / 6-digit code). No code in it: the TV is already in.
export async function sendDeviceNotice(env, to, device, rejectUrl) {
    const foot = 'If this was you, there is nothing to do. If it was not you, choose \"Forgot password\" in the app or on the website to set a new password: that signs every other device out.';
    return postMail(env, to, 'New sign-in on PEK TV: ' + device.name,
        'A device was just signed in to your PEK TV account.\n' + deviceText(device) + '\nIf this was you, there is nothing to do. If it was not you, choose \"Forgot password\" in the app or on the website to set a new password: that signs every other device out.' + (rejectUrl ? '\n\nWasn\'t you? Reject this login: ' + rejectUrl : ''),
        mailHtml('A device was signed in', 'Your PEK TV account was just signed in on this device:', '', device, foot, rejectUrl));
}

// The website page that confirms a rejection (a button there does the POST, so an email scanner opening the link changes nothing).
export function webUrl(env) { return String(env.WEB_URL || 'https://pekindustries.com/pektv').replace(/\/+$/, ''); }
// Makes the one-time link for "Wasn't you? Reject this login". kind 'login' = a sign-in code was sent; kind 'device' = a TV was approved (ref = its poll hash).
export async function makeRejectUrl(env, db, userId, kind, ref, now) {
    const token = randomToken();
    await db.prepare('INSERT INTO reject_tokens (hash, user_id, kind, ref, created, expires) VALUES (?, ?, ?, ?, ?, ?)')
        .bind(await sha256Hex('hesper:reject:' + token), userId, kind, ref || '', now, now + REJECT_TTL).run();
    return webUrl(env) + '/reject.html?t=' + token;
}

export function emailReady(env) { return !!(env.BREVO_API_KEY && env.BREVO_SENDER_EMAIL); }

// Makes a fresh verification code for an unverified account and emails it.
// Returns false when the per-email hourly limit stopped it from sending.
export async function issueVerification(env, db, userId, email, now) {
    if (await limited(db, 'verify:mail:' + email, 5, 3600 * 1000, now)) return false;
    const code = sixDigits();
    await db.prepare('INSERT INTO verifs (user_id, code_hash, expires, tries) VALUES (?, ?, ?, 0) ' +
        'ON CONFLICT(user_id) DO UPDATE SET code_hash = excluded.code_hash, expires = excluded.expires, tries = 0')
        .bind(userId, await sha256Hex('hesper:verify:' + userId + ':' + code), now + VERIFY_TTL).run();
    try { await sendCodeEmail(env, email, code, 'verify'); } catch (e) { console.error('Brevo request error', String(e)); }
    await db.prepare('UPDATE invites SET reserved_until = ? WHERE reserved_by = ? AND used_by IS NULL').bind(now + VERIFY_TTL, userId).run();   // the invite stays held while this code works
    return true;
}

// Every sign-in of a confirmed account asks for an emailed code too (the password alone is not enough).
// Same table and check as the sign-up code: the app exchanges it at /v1/auth/verify for the session token.
// Returns 'sent', 'limited' (too many codes this hour) or 'failed' (the email could not be sent).
export async function issueLoginCode(env, db, userId, email, now, device) {
    if (await limited(db, 'login:code:' + email, 6, 3600 * 1000, now)) return 'limited';
    const code = sixDigits();
    await db.prepare('INSERT INTO verifs (user_id, code_hash, expires, tries) VALUES (?, ?, ?, 0) ' +
        'ON CONFLICT(user_id) DO UPDATE SET code_hash = excluded.code_hash, expires = excluded.expires, tries = 0')
        .bind(userId, await sha256Hex('hesper:verify:' + userId + ':' + code), now + VERIFY_TTL).run();
    try {
        const rejectUrl = device ? await makeRejectUrl(env, db, userId, 'login', '', now) : '';
        return (await sendCodeEmail(env, email, code, 'login', device || null, rejectUrl)) ? 'sent' : 'failed';
    }
    catch (e) { console.error('Brevo request error', String(e)); return 'failed'; }
}
