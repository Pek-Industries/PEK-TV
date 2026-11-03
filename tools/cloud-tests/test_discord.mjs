// Runs the Discord link flow (cloud/worker.js: /v1/discord/*) against a real SQLite database, with Discord's token
// endpoint replaced by a fake. Needs Node 22 or newer. From this folder: sh run.sh
import { makeDB } from './d1shim.mjs';
import worker from './worker.mjs';

const db = makeDB();
const env = { DB: db, DISCORD_CLIENT_ID: '1234567890', DISCORD_CLIENT_SECRET: 'sekret', SITE_URL: 'https://pekindustries.com/pektv' };
let fail = 0;
const check = (n, ok, x = '') => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (x ? '  (' + x + ')' : '')); if (!ok) fail++; };

// A fake Discord: records what the worker sends and answers like the real token endpoint.
const calls = [];
let tokenMode = 'ok';
globalThis.fetch = async (url, init = {}) => {
  const body = init.body ? Object.fromEntries(new URLSearchParams(String(init.body))) : {};
  calls.push({ url: String(url), body });
  if (String(url).endsWith('/oauth2/token/revoke')) return new Response('{}', { status: 200 });
  if (String(url).endsWith('/oauth2/token')) {
    if (tokenMode === 'bad') return new Response(JSON.stringify({ error: 'invalid_grant' }), { status: 400 });
    if (body.grant_type === 'refresh_token' && body.refresh_token !== 'refresh-1-abcdefghij') return new Response(JSON.stringify({ error: 'invalid_grant' }), { status: 400 });
    const n = body.grant_type === 'refresh_token' ? '2' : '1';
    return new Response(JSON.stringify({ access_token: 'access-' + n + '-abcdefghij', refresh_token: 'refresh-' + n + '-abcdefghij', expires_in: 604800, scope: 'openid sdk.social_layer_presence', token_type: 'Bearer' }), { status: 200 });
  }
  return new Response('{}', { status: 404 });
};

const post = (path, obj) => worker.fetch(new Request('https://w.example' + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) }), env);
const get = (path) => worker.fetch(new Request('https://w.example' + path, { method: 'GET', redirect: 'manual' }), env);

// not configured
const off = await worker.fetch(new Request('https://w.example/v1/discord/start', { method: 'POST', body: '{}' }), { DB: db });
check('start says not configured when the secrets are missing', off.status === 503 && (await off.json()).error === 'discord_not_configured');

// start
let r = await post('/v1/discord/start', {});
let start = await r.json();
check('start gives a poll secret, a link and the app id', r.status === 200 && start.ok && start.poll.length >= 20 && start.appId === '1234567890' && /^https:\/\/w\.example\/v1\/discord\/go\?s=[a-f0-9]{32}$/.test(start.url), start.url);
const state = start.url.split('s=')[1];

// pending before approval
r = await post('/v1/discord/poll', { poll: start.poll });
check('poll is pending until Discord is approved', (await r.json()).status === 'pending');

// go -> Discord's approval page
r = await get('/v1/discord/go?s=' + state);
const loc = r.headers.get('Location') || '';
check('go forwards to Discord with the presence scopes, our callback and the state', r.status === 302 && loc.startsWith('https://discord.com/oauth2/authorize?') && loc.includes('client_id=1234567890') && loc.includes('scope=openid%20sdk.social_layer_presence') && loc.includes(encodeURIComponent('https://w.example/v1/discord/callback')) && loc.includes('state=' + state), loc);
r = await get('/v1/discord/go?s=' + 'a'.repeat(32));
check('go refuses an unknown state', r.status === 410);
r = await get('/v1/discord/go?s=nope');
check('go refuses a malformed state', r.status === 410);

// denied on Discord's page (no code)
r = await get('/v1/discord/callback?state=' + state);
check('callback without a code says not linked and keeps the link usable', r.status === 400);

// approved
r = await get('/v1/discord/callback?state=' + state + '&code=abc123');
const ex = calls.find((c) => c.url.endsWith('/oauth2/token') && c.body.grant_type === 'authorization_code');
check('callback exchanges the code with the client secret and our redirect', r.status === 200 && ex && ex.body.code === 'abc123' && ex.body.client_secret === 'sekret' && ex.body.redirect_uri === 'https://w.example/v1/discord/callback');
r = await get('/v1/discord/callback?state=' + state + '&code=again');
check('the same link cannot be used twice', r.status === 410);

// poll takes the tokens once
r = await post('/v1/discord/poll', { poll: start.poll });
let got = await r.json();
check('poll hands over the tokens and the app id', got.status === 'approved' && got.access_token === 'access-1-abcdefghij' && got.refresh_token === 'refresh-1-abcdefghij' && got.expires_in === 604800 && got.appId === '1234567890');
r = await post('/v1/discord/poll', { poll: start.poll });
check('the tokens are only handed over once', r.status === 410);
check('nothing is left in the database after pickup', db._raw.prepare('SELECT COUNT(*) AS n FROM discord_links').get().n === 0);

// a wrong poll secret gets nothing
r = await post('/v1/discord/poll', { poll: 'x'.repeat(40) });
check('a wrong poll secret gets nothing', r.status === 410);

// Discord refuses the code
tokenMode = 'bad';
start = await (await post('/v1/discord/start', {})).json();
r = await get('/v1/discord/callback?state=' + start.url.split('s=')[1] + '&code=nope');
check('callback reports it when Discord refuses the code', r.status === 502);
r = await post('/v1/discord/poll', { poll: start.poll });
check('and the app keeps waiting instead of getting tokens', (await r.json()).status === 'pending');
tokenMode = 'ok';

// an expired link
start = await (await post('/v1/discord/start', {})).json();
db._raw.prepare('UPDATE discord_links SET expires = ?').run(Date.now() - 1000);
r = await get('/v1/discord/go?s=' + start.url.split('s=')[1]);
check('an expired link is refused', r.status === 410);
r = await post('/v1/discord/poll', { poll: start.poll });
check('an expired link tells the app to start again', r.status === 410);

// refresh
r = await post('/v1/discord/refresh', { refresh_token: 'refresh-1-abcdefghij' });
got = await r.json();
check('refresh returns a new pair', r.status === 200 && got.access_token === 'access-2-abcdefghij' && got.refresh_token === 'refresh-2-abcdefghij');
r = await post('/v1/discord/refresh', { refresh_token: 'revoked-token-abcdefghij' });
check('refresh with a dead token says invalid_token', r.status === 401 && (await r.json()).error === 'invalid_token');
r = await post('/v1/discord/refresh', { refresh_token: 'x' });
check('refresh with junk says invalid_token', r.status === 401);

// revoke
calls.length = 0;
r = await post('/v1/discord/revoke', { token: 'access-2-abcdefghij' });
const rv = calls.find((c) => c.url.endsWith('/oauth2/token/revoke'));
check('revoke asks Discord to forget the grant', r.status === 200 && rv && rv.body.token === 'access-2-abcdefghij' && rv.body.client_secret === 'sekret');

// rate limit on start
let limited = false;
for (let i = 0; i < 30 && !limited; i++) limited = (await post('/v1/discord/start', {})).status === 429;
check('start is rate limited per address', limited);

console.log(fail ? '\n' + fail + ' FAILED' : '\nALL PASSED');
process.exit(fail ? 1 : 0);
