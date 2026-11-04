import { json } from './config.js';
import { randomHex, randomToken, sha256Hex } from './crypto.js';
import { clientIp, limited, readJson } from './input.js';
import { sessionFor } from './sessions.js';

// ---------------------------------------------------------------- Discord link (Rich Presence: "Watching ..." on the person's Discord profile)
// 1. The app (a TV shows a QR code, a phone opens the link) asks /v1/discord/start for a link and keeps the secret `poll` value.
// 2. The person opens the link: /v1/discord/go sends them to Discord's own approval page, Discord sends them back to
//    /v1/discord/callback, which swaps the code for tokens (the client secret never leaves this worker) and keeps them for the app.
// 3. The app polls /v1/discord/poll with its secret and takes the tokens exactly once (the row is deleted as it is read).
// Tokens wait here for at most DISCORD_TTL. Presence itself is set on the device by the Discord Social SDK, never by this worker.
// Needs the secrets DISCORD_CLIENT_ID and DISCORD_CLIENT_SECRET, and https://<this worker>/v1/discord/callback registered as a
// redirect in the Discord developer portal (see DISCORD.md).
export const DISCORD_TTL = 10 * 60 * 1000;
export const DISCORD_SCOPE = 'openid sdk.social_layer_presence';   // what the Social SDK's GetDefaultPresenceScopes() returns
export const DISCORD_API = 'https://discord.com/api/v10';

export function discordReady(env) { return !!(env.DISCORD_CLIENT_ID && env.DISCORD_CLIENT_SECRET); }

// Discord can only be linked from a signed-in PEK account: start, poll, refresh and revoke all need the PEK session token
// (Authorization: Bearer ...). The poll secret is also tied to the account that started the link, so another account's session
// (or a leaked poll value) cannot pick the tokens up. /go and /callback are opened in a browser (a phone that scanned the TV's QR
// code is not signed in to PEK) and are protected by the unguessable one-use `state` that only a signed-in start can create.
export async function discordPollHash(userId, poll) { return sha256Hex('pek:discord:poll:' + userId + ':' + poll); }

export async function discordToken(env, params) {
    const body = new URLSearchParams(Object.assign({ client_id: env.DISCORD_CLIENT_ID, client_secret: env.DISCORD_CLIENT_SECRET }, params));
    const r = await fetch(DISCORD_API + '/oauth2/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': 'PEK-TV (https://pekindustries.com, 1.0)' },
        body
    });
    let data = null;
    try { data = await r.json(); } catch (e) { /* not JSON */ }
    data = data || {};
    return { ok: r.ok && typeof data.access_token === 'string' && typeof data.refresh_token === 'string', status: r.status, data };
}

export function discordPage(title, text, status = 200) {
    const html = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' + title + '</title>' +
        '<style>body{font-family:system-ui,sans-serif;background:#111;color:#eee;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0;padding:1.5rem;text-align:center}' +
        'h1{font-size:1.4rem;margin:0 0 .6rem}p{margin:0;color:#aaa;line-height:1.5}</style></head><body><div><h1>' + title + '</h1><p>' + text + '</p></div></body></html>';
    return new Response(html, { status, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
}

export async function discordStart(request, env) {
    if (!discordReady(env)) return json({ error: 'discord_not_configured' }, 503);
    const db = env.DB, now = Date.now();
    const sess = await sessionFor(request, db, now);
    if (!sess) return json({ error: 'bad_session' }, 401);
    if (await limited(db, 'discord:start:' + sess.userId, 20, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    await db.prepare('DELETE FROM discord_links WHERE expires < ?').bind(now).run();
    const poll = randomToken();
    const state = randomHex(16);
    await db.prepare('INSERT INTO discord_links (poll_hash, state, created, expires, scope) VALUES (?, ?, ?, ?, ?)')
        .bind(await discordPollHash(sess.userId, poll), state, now, now + DISCORD_TTL, DISCORD_SCOPE).run();
    const origin = new URL(request.url).origin;
    return json({ ok: true, poll, url: origin + '/v1/discord/go?s=' + state, appId: String(env.DISCORD_CLIENT_ID), expiresIn: Math.floor(DISCORD_TTL / 1000), interval: 3 });
}

// The QR code / button opens this: it only forwards to Discord's approval page.
export async function discordGo(url, request, env) {
    if (!discordReady(env)) return discordPage('Discord is not set up', 'This PEK Cloud does not have Discord linking turned on.', 503);
    const now = Date.now();
    if (await limited(env.DB, 'discord:go:' + clientIp(request), 60, 10 * 60 * 1000, now)) return discordPage('Too many tries', 'Wait a few minutes and try again.', 429);
    const state = url.searchParams.get('s') || '';
    const row = /^[a-f0-9]{32}$/.test(state) ? await env.DB.prepare('SELECT expires, access FROM discord_links WHERE state = ?').bind(state).first() : null;
    if (!row || row.expires < now || row.access) return discordPage('This link has expired', 'Go back to PEK TV and start again.', 410);
    const to = 'https://discord.com/oauth2/authorize?client_id=' + encodeURIComponent(env.DISCORD_CLIENT_ID) +
        '&response_type=code&scope=' + encodeURIComponent(DISCORD_SCOPE) +
        '&redirect_uri=' + encodeURIComponent(url.origin + '/v1/discord/callback') + '&state=' + state;
    return new Response(null, { status: 302, headers: { Location: to, 'Cache-Control': 'no-store' } });
}

export async function discordCallback(url, env) {
    const now = Date.now();
    const state = url.searchParams.get('state') || '', code = url.searchParams.get('code') || '';
    const row = /^[a-f0-9]{32}$/.test(state) ? await env.DB.prepare('SELECT expires, access FROM discord_links WHERE state = ?').bind(state).first() : null;
    if (!row || row.expires < now || row.access) return discordPage('This link has expired', 'Go back to PEK TV and start again.', 410);
    if (!code) return discordPage('Not linked', 'Discord was not approved. You can close this page and try again from PEK TV.', 400);
    let t = null;
    try { t = await discordToken(env, { grant_type: 'authorization_code', code, redirect_uri: url.origin + '/v1/discord/callback' }); }
    catch (e) { console.error('Discord token error', String(e)); }
    if (!t || !t.ok) return discordPage('Not linked', 'Discord did not accept the link. Go back to PEK TV and try again.', 502);
    // one use only: the row takes the tokens once
    const upd = await env.DB.prepare('UPDATE discord_links SET access = ?, refresh = ?, expires_in = ?, scope = ? WHERE state = ? AND access IS NULL')
        .bind(t.data.access_token, t.data.refresh_token, Math.max(0, Math.floor(Number(t.data.expires_in) || 0)), String(t.data.scope || DISCORD_SCOPE), state).run();
    if (!upd.meta || upd.meta.changes !== 1) return discordPage('This link has expired', 'Go back to PEK TV and start again.', 410);
    return discordPage('Discord linked', 'You can close this page and go back to PEK TV.');
}

export async function discordPoll(request, env) {
    const db = env.DB, now = Date.now();
    const sess = await sessionFor(request, db, now);
    if (!sess) return json({ error: 'bad_session' }, 401);
    const { body, err } = await readJson(request); if (err) return err;
    const poll = typeof body.poll === 'string' ? body.poll : '';
    if (poll.length < 20 || poll.length > 100) return json({ error: 'expired' }, 410);
    const pollHash = await discordPollHash(sess.userId, poll);
    if (await limited(db, 'discord:poll:' + pollHash, 400, DISCORD_TTL, now)) return json({ error: 'rate_limited' }, 429);
    const row = await db.prepare('SELECT access, refresh, expires_in, scope, expires FROM discord_links WHERE poll_hash = ?').bind(pollHash).first();
    if (!row || row.expires < now) return json({ error: 'expired' }, 410);
    if (!row.access) return json({ ok: true, status: 'pending' });
    const del = await db.prepare('DELETE FROM discord_links WHERE poll_hash = ? AND access IS NOT NULL').bind(pollHash).run();
    if (!del.meta || del.meta.changes !== 1) return json({ ok: true, status: 'pending' });
    return json({ ok: true, status: 'approved', appId: String(env.DISCORD_CLIENT_ID), access_token: row.access, refresh_token: row.refresh, expires_in: row.expires_in, scope: row.scope });
}

// Discord's access tokens last about 7 days. The app swaps its refresh token for a new pair here (the client secret is needed).
export async function discordRefresh(request, env) {
    if (!discordReady(env)) return json({ error: 'discord_not_configured' }, 503);
    const now = Date.now();
    const sess = await sessionFor(request, env.DB, now);
    if (!sess) return json({ error: 'bad_session' }, 401);
    const { body, err } = await readJson(request); if (err) return err;
    if (await limited(env.DB, 'discord:refresh:' + sess.userId, 60, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    const refresh = typeof body.refresh_token === 'string' ? body.refresh_token : '';
    if (refresh.length < 10 || refresh.length > 300) return json({ error: 'invalid_token' }, 401);
    let t = null;
    try { t = await discordToken(env, { grant_type: 'refresh_token', refresh_token: refresh }); }
    catch (e) { return json({ error: 'server' }, 502); }
    if (!t.ok) return t.status >= 400 && t.status < 500 ? json({ error: 'invalid_token' }, 401) : json({ error: 'server' }, 502);
    return json({ ok: true, access_token: t.data.access_token, refresh_token: t.data.refresh_token, expires_in: Math.max(0, Math.floor(Number(t.data.expires_in) || 0)), scope: String(t.data.scope || DISCORD_SCOPE) });
}

// "Unlink Discord": ask Discord to forget the grant. Best effort; the app forgets its tokens either way.
export async function discordRevoke(request, env) {
    if (!discordReady(env)) return json({ ok: true });
    const now = Date.now();
    const sess = await sessionFor(request, env.DB, now);
    if (!sess) return json({ error: 'bad_session' }, 401);
    const { body, err } = await readJson(request); if (err) return err;
    if (await limited(env.DB, 'discord:revoke:' + sess.userId, 60, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    const token = typeof body.token === 'string' ? body.token : '';
    if (token.length < 10 || token.length > 300) return json({ ok: true });
    try {
        await fetch(DISCORD_API + '/oauth2/token/revoke', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': 'PEK-TV (https://pekindustries.com, 1.0)' },
            body: new URLSearchParams({ client_id: env.DISCORD_CLIENT_ID, client_secret: env.DISCORD_CLIENT_SECRET, token })
        });
    } catch (e) { /* best effort */ }
    return json({ ok: true });
}
