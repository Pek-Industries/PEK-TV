// PEK Cloud: accounts + sync service for watch history and resume positions.
// Runs as a Cloudflare Worker with ONE D1 database bound as "DB".
//
// Accounts are an email address and a password.
//   - Passwords are stored only as salted PBKDF2-SHA256 hashes.
//   - A sign-in gives the device a random session token (only its SHA-256 hash is stored).
//   - New accounts must verify their email: sign-up emails a 6-digit code (Brevo, https://www.brevo.com),
//     and the device is only signed in once the code is entered.
//   - "Forgot password" emails a 6-digit code the same way (and also counts as verifying the email).
//
// Settings (Worker -> Settings -> Variables and Secrets):
//   BREVO_API_KEY       (Secret)  your Brevo API key
//   BREVO_SENDER_EMAIL  (Text)    a sender address you verified in Brevo
//   BREVO_SENDER_NAME   (Text, optional)  shown as the sender name, default "PEK TV"
//   DELETE_DAYS         (Text, optional)  days a lapsed account has to subscribe again after the grace, before it is deleted (default 30; also set it on pek-billing)
//   Cron trigger        (Settings -> Triggers) `0 3 * * *` runs the daily job for lapsed plans (see cloud/BILLING-DEPLOY.md, "When a plan lapses")
//   INVITE_ONLY        (Text, optional)  1 = new accounts need a single-use invite code (existing accounts are not affected)
//   ADMIN_KEY          (Secret, optional) a long random text (16+ characters); lets YOU make invite codes (see cloud/DEPLOY.md)
//
// Plans (paid with Stripe on the website by cloud/billing-worker.js, which shares this D1 database; see cloud/BILLING-DEPLOY.md):
//   free         account only: no cloud backup (sync, profile sync, plugin backup answer 402 subscription_required), 1 profile in the app
//   grandfathered accounts that existed before plans were added: everything unlocked, forever
//   monthly / yearly  paid while plan_until is in the future (the billing worker moves it forward on every renewal)
//   lifetime     paid once, everything unlocked, forever
//
// Routes:
//   POST   /v1/auth/signup   { email, username, password, invite? } -> { ok, needsVerify, email }   (username is required: 3 to 20 letters, digits . _ -; code emailed; invite needed when INVITE_ONLY=1)
//                                                                  Sign-up is done on the website (public/pektv/account.html); the app only signs in.
//   GET    /v1/news                                             -> { ok, items }   (public: the app's Updates screen)
//   POST   /v1/news/post     { title, body?, kind?, code?, link?, days? }  (Authorization: Bearer <ADMIN_KEY>; kind = news | update | coupon)
//   POST   /v1/news/list  and  /v1/news/delete { id }           (same key)
//   POST   /v1/invites/new   { count?, days?, note? }           -> { ok, codes }   (Authorization: Bearer <ADMIN_KEY>; codes are shown once)
//   POST   /v1/invites/list  {}                                 -> { ok, invites }   (same key)   POST /v1/invites/revoke { id } -> { ok }
//   POST   /v1/auth/verify   { email, code }                    -> { ok, token, email }   (finishes a sign-up OR a sign-in)
//   POST   /v1/auth/resend   { email }                          -> { ok }   (always; new code for an unconfirmed account or a pending sign-in)
//   POST   /v1/auth/login    { email, password }                -> { ok, needsVerify, email }  (a 6-digit code is emailed; every sign-in needs it)
//                                                                  or 403 email_not_verified (new account that never confirmed its email)
//   POST   /v1/auth/forgot   { email }                          -> { ok }   (always, so emails can't be probed)
//   POST   /v1/auth/reset    { email, code, password }          -> { ok, token, email }
//   POST   /v1/subs/search   { title, year?, season?, episode?, lang?, file? } -> { ok, results }   (shared OpenSubtitles account, no sign-in)
//   POST   /v1/subs/get      { id }                                            -> { ok, text, cached }  (see "subtitles" below)
//   POST   /v1/auth/logout                                      -> { ok }
//   POST   /v1/account/username { username }                    -> { ok, username }   (only for an older account that has none yet; it cannot be changed afterwards)
//   GET    /v1/me                                               -> { ok, email, username, plan, entitled, until, cancelling, since, lapse: { state, graceEnds, deleteAt }, now }   (works on every plan; 410 account_deleted once a lapsed account was deleted)
//   POST   /v1/auth/confirm  { password }                      -> { ok }   (re-checks the signed-in account's password, e.g. to reset a forgotten profile passcode; rate limited)
//   POST   /v1/profiles/sync { profiles: [{id,name,color,updated,deleted,avatar,pin}] } -> { ok, profiles, rejected }   (the household's profiles, last writer wins;
//                                                                  avatar = built-in picture id or a small photo, pin = salted passcode hash, both optional)
//   POST   /v1/sync          push changed items (history, progress, favorites, settings, skins, ratings) of ONE profile ({ profile, since, ... }), pull newer ones
//   GET    /v1/plugins                                          -> { ok, plugins: [{id,name,version,size,fp,updated,deleted,chunks}] }
//   POST   /v1/plugins/chunk   { id, fp, index, total, data }   -> { ok }      (one piece of a plugin backup)
//   POST   /v1/plugins/commit  { id, fp, total, name, version, size, updated } -> { ok, stored }  (finishes a backup)
//   GET    /v1/plugins/chunk?id=&fp=&i=                         -> { ok, data }
//   POST   /v1/plugins/delete  { id, updated }                  -> { ok }
//   GET    /v1/export        everything stored for the account (JSON; works on every plan)
//   DELETE /v1/account       permanently delete the account and all its data (409 cancel_subscription_first while a renewing subscription is active)
//
//   Plugin Store (see DEPLOY.md). Uploads need a GitHub sign-in, done on the GitHub Pages site:
//   GET    /v1/gh/login?ret=upload|owner  -> redirects to GitHub;  GET /v1/gh/callback -> back to the site with #token=
//   GET    /v1/store?shelf=official|community                   -> { ok, items }          (public)
//   GET    /v1/store/chunk?id=&fp=&i=                           -> { ok, data }           (public, approved only)
//   POST   /v1/store/chunk | /v1/store/submit | /v1/store/remove ; GET /v1/store/mine ; GET /v1/gh/me   (GitHub token)
//   POST   /v1/store/owner/{chunk,commit,approve,remove} ; GET /v1/store/owner/{all,chunk}             (owner accounts only)
//
// Everything except /v1/auth/{signup,verify,resend,login,forgot,reset} needs:  Authorization: Bearer <session token>


import { handleDelete, handleExport, handleMe, handleSetUsername, planOf } from './account.js';
import { handleInvites } from './admin.js';
import { handleForgot, handleLogin, handleLogout, handleResend, handleReset, handleSignup, handleVerify } from './auth.js';
import { CORS, json } from './config.js';
import { init } from './db.js';
import { handleDeviceApprove, handleDeviceInfo, handleDevicePoll, handleDeviceReject, handleDeviceStart, handleRejectToken } from './device.js';
import { discordCallback, discordGo, discordPoll, discordRefresh, discordRevoke, discordStart } from './discord.js';
import { runLifecycle, sessionWasDeleted } from './lifecycle.js';
import { handleNews, handleNewsList } from './news.js';
import { handlePluginChunk, handlePluginCommit, handlePluginDelete, handlePluginGetChunk, handlePluginList } from './plugin-backup.js';
import { sessionFor } from './sessions.js';
import { ghCallback, ghLogin, ghSession, storeCommit, storeGetChunk, storeList, storeMine, storeOwnerAll, storeOwnerApprove, storePutChunk, storeRemove } from './store.js';
import { handleSubsGet, handleSubsSearch } from './subtitles.js';
import { handleConfirm, handleProfiles, handleSync } from './sync.js';

export default {
    // Cloudflare cron trigger (Worker -> Settings -> Triggers -> Cron: 0 3 * * *): the daily job for lapsed plans.
    async scheduled(event, env, ctx) {
        ctx.waitUntil(runLifecycle(env).catch(e => console.error('lifecycle job failed', String(e && e.stack || e))));
    },
    async fetch(request, env) {
        if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
        const url = new URL(request.url);
        const path = url.pathname, method = request.method;
        if (path === '/' && method === 'GET') {
            return new Response('PEK-sync ok', { headers: Object.assign({ 'Content-Type': 'text/plain' }, CORS) });
        }
        try {
            if (!env.DB) return json({ error: 'no_database_bound' }, 500);
            await init(env.DB);

            if (method === 'POST' && path === '/v1/auth/signup') return await handleSignup(request, env);
            if (method === 'POST' && path === '/v1/auth/verify') return await handleVerify(request, env);
            if (method === 'POST' && path === '/v1/auth/resend') return await handleResend(request, env);
            if (method === 'POST' && path === '/v1/auth/login') return await handleLogin(request, env);
            if (method === 'POST' && path === '/v1/auth/forgot') return await handleForgot(request, env);
            if (method === 'POST' && path === '/v1/auth/reset') return await handleReset(request, env);
            if (method === 'POST' && path === '/v1/auth/reject') return await handleRejectToken(request, env);
            if (method === 'POST' && path === '/v1/device/start') return await handleDeviceStart(request, env);
            if (method === 'POST' && path === '/v1/device/poll') return await handleDevicePoll(request, env);
            if (method === 'POST' && path === '/v1/discord/start') return await discordStart(request, env);
            if (method === 'POST' && path === '/v1/discord/poll') return await discordPoll(request, env);
            if (method === 'POST' && path === '/v1/discord/refresh') return await discordRefresh(request, env);
            if (method === 'POST' && path === '/v1/discord/revoke') return await discordRevoke(request, env);
            if (method === 'GET' && path === '/v1/discord/go') return await discordGo(url, request, env);
            if (method === 'GET' && path === '/v1/discord/callback') return await discordCallback(url, env);
            if (method === 'POST' && path.indexOf('/v1/invites/') === 0) return await handleInvites(request, env, path);
            if (method === 'GET' && path === '/v1/news') return await handleNewsList(env);
            if (method === 'POST' && path.indexOf('/v1/news/') === 0) return await handleNews(request, env, path);

            // Subtitles: no sign-in needed (everyone shares the server's OpenSubtitles account)
            if (method === 'POST' && path === '/v1/subs/search') return await handleSubsSearch(request, env);
            if (method === 'POST' && path === '/v1/subs/get') return await handleSubsGet(request, env);

            // GitHub sign-in (used by the GitHub Pages site)
            if (method === 'GET' && path === '/v1/gh/login') return await ghLogin(url, request, env);
            if (method === 'GET' && path === '/v1/gh/callback') return await ghCallback(url, env);
            // Plugin Store: browsing and downloading need no sign-in at all
            if (method === 'GET' && path === '/v1/store') return await storeList(url, env);
            if (method === 'GET' && path === '/v1/store/chunk') return await storeGetChunk(url, env, false);
            // Plugin Store: uploads and owner tools need a GitHub sign-in
            if (path.indexOf('/v1/store/') === 0 || path.indexOf('/v1/gh/') === 0) {
                const who = await ghSession(request, env, Date.now());
                if (!who) return json({ error: 'bad_session' }, 401);
                if (method === 'GET' && path === '/v1/gh/me') return json({ ok: true, login: who.login, owner: who.owner });
                if (method === 'POST' && path === '/v1/gh/logout') { await env.DB.prepare('DELETE FROM gh_sessions WHERE token_hash = ?').bind(who.hash).run(); return json({ ok: true }); }
                if (method === 'POST' && path === '/v1/store/chunk') return await storePutChunk(request, env, who);
                if (method === 'POST' && path === '/v1/store/submit') return await storeCommit(request, env, who, false);
                if (method === 'GET' && path === '/v1/store/mine') return await storeMine(env, who);
                if (method === 'POST' && path === '/v1/store/remove') return await storeRemove(request, env, who, false);
                if (path.indexOf('/v1/store/owner/') === 0) {
                    if (!who.owner) return json({ error: 'forbidden' }, 403);
                    if (method === 'POST' && path === '/v1/store/owner/chunk') return await storePutChunk(request, env, who);
                    if (method === 'POST' && path === '/v1/store/owner/commit') return await storeCommit(request, env, who, true);
                    if (method === 'GET' && path === '/v1/store/owner/chunk') return await storeGetChunk(url, env, true);
                    if (method === 'GET' && path === '/v1/store/owner/all') return await storeOwnerAll(env);
                    if (method === 'POST' && path === '/v1/store/owner/approve') return await storeOwnerApprove(request, env);
                    if (method === 'POST' && path === '/v1/store/owner/remove') return await storeRemove(request, env, who, true);
                }
                return json({ error: 'not_found' }, 404);
            }

            const sess = await sessionFor(request, env.DB, Date.now());
            if (!sess) {
                if (await sessionWasDeleted(request, env.DB)) return json({ error: 'account_deleted' }, 410);
                return json({ error: 'bad_session' }, 401);
            }

            if (method === 'POST' && path === '/v1/auth/logout') return await handleLogout(env, sess);
            if (method === 'GET' && path === '/v1/me') return await handleMe(env, sess.userId);
            if (method === 'POST' && path === '/v1/device/info') return await handleDeviceInfo(request, env, sess.userId);
            if (method === 'POST' && path === '/v1/device/approve') return await handleDeviceApprove(request, env, sess.userId);
            if (method === 'POST' && path === '/v1/device/reject') return await handleDeviceReject(request, env, sess.userId);
            if (method === 'POST' && path === '/v1/account/username') return await handleSetUsername(request, env, sess.userId);
            // Cloud backup (profile sync, watch-history sync, plugin backup) is a paid feature. Export and account deletion stay free.
            if (path === '/v1/profiles/sync' || path === '/v1/sync' || path.indexOf('/v1/plugins') === 0) {
                if (!(await planOf(env.DB, sess.userId, Date.now())).entitled) return json({ error: 'subscription_required' }, 402);
            }
            if (method === 'POST' && path === '/v1/auth/confirm') return await handleConfirm(request, env, sess.userId);
            if (method === 'POST' && path === '/v1/profiles/sync') return await handleProfiles(request, env, sess.userId);
            if (method === 'POST' && path === '/v1/sync') return await handleSync(request, env, sess.userId);
            if (method === 'GET' && path === '/v1/plugins') return await handlePluginList(env, sess.userId);
            if (method === 'POST' && path === '/v1/plugins/chunk') return await handlePluginChunk(request, env, sess.userId);
            if (method === 'POST' && path === '/v1/plugins/commit') return await handlePluginCommit(request, env, sess.userId);
            if (method === 'GET' && path === '/v1/plugins/chunk') return await handlePluginGetChunk(url, env, sess.userId);
            if (method === 'POST' && path === '/v1/plugins/delete') return await handlePluginDelete(request, env, sess.userId);
            if (method === 'GET' && path === '/v1/export') return await handleExport(env, sess.userId);
            if (method === 'DELETE' && path === '/v1/account') return await handleDelete(env, sess.userId);
            return json({ error: 'not_found' }, 404);
        } catch (e) {
            console.error('worker error', String(e && e.stack || e));
            return json({ error: 'server_error' }, 500);
        }
    }
};
