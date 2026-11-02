import { makeDB } from './d1shim.mjs';
import worker from './worker.mjs';
import { createHash } from 'node:crypto';
const DAY = 86400000, now = Date.now();
const db = makeDB(), env = { DB: db };
let fail = 0;
const check = (n, ok, x = '') => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (x ? '  (' + x + ')' : '')); if (!ok) fail++; };
const sha = (t) => createHash('sha256').update(t).digest('hex');
const me = async (tok) => { const r = await worker.fetch(new Request('https://x/v1/me', { headers: { Authorization: 'Bearer ' + tok } }), env); return { status: r.status, body: await r.json() }; };
await worker.fetch(new Request('https://x/v1/me'), env);            // creates every table
const raw = db._raw;
let n = 0;
function addUser(name, f) {
  const id = 'u_' + name, tok = 'token-' + name + '-'.repeat(20);
  raw.prepare("INSERT INTO users (id,email,pw,created,last_seen,verified,gf,username,plan,plan_until,plan_cancel,plan_since,delete_at,notice_stage) VALUES (?,?,?,?,?,1,0,?,?,?,?,?,?,?)")
     .run(id, name + '@example.com', 'x', now, now, name + (n++), f.plan, f.until ?? 0, f.cancel ?? 0, f.since ?? 0, f.delete_at ?? 0, 0);
  raw.prepare("INSERT INTO sessions (token_hash,user_id,created,expires) VALUES (?,?,?,?)").run(sha('hesper:session:' + tok), id, now, now + 30 * DAY);
  raw.prepare("INSERT INTO items (acct,kind,key,data,updated,deleted,srv) VALUES (?,?,?,?,?,0,1)").run(id, 'w', 'k1', '{}', now);
  return tok;
}
const hasUser = (name) => !!raw.prepare('SELECT 1 FROM users WHERE id = ?').get('u_' + name);
const hasItems = (name) => !!raw.prepare('SELECT 1 FROM items WHERE acct = ?').get('u_' + name);
const row = (name) => raw.prepare('SELECT * FROM users WHERE id = ?').get('u_' + name);

const T = {
  active:   addUser('active',   { plan: 'monthly',  until: now + 20 * DAY, since: now - 100 * DAY }),
  grace:    addUser('grace',    { plan: 'monthly',  until: now + 2 * DAY,  since: now - 400 * DAY }),
  locked:   addUser('locked',   { plan: 'yearly',   until: now - 1 * DAY }),
  lockedOld:addUser('lockedold',{ plan: 'monthly',  until: now - 40 * DAY }),
  cancelled:addUser('cancelled',{ plan: 'free',     delete_at: now + 10 * DAY }),
  expired:  addUser('expired',  { plan: 'free',     delete_at: now - 1 * DAY }),
  neverPaid:addUser('neverpaid',{ plan: 'free' }),
  lifetime: addUser('lifetime', { plan: 'lifetime', delete_at: now - 5 * DAY, since: now - 9 * DAY }),
  gf:       addUser('gf',       { plan: 'grandfathered', delete_at: now - 5 * DAY }),
  racing:   addUser('racing',   { plan: 'monthly',  until: now + 5 * DAY, delete_at: now - 1 * DAY }),
};
let r;
r = await me(T.active);   check('active plan: no lapse, shows subscribed date', r.body.lapse.state === 'none' && Math.abs(r.body.since - (now - 100 * DAY)) < 1000);
r = await me(T.grace);    check('missed renewal: state grace with end date', r.body.lapse.state === 'grace' && r.body.entitled === true && Math.abs(r.body.lapse.graceEnds - (now + 2 * DAY)) < 1000);
r = await me(T.locked);   check('grace over: state deletion, backup off', r.body.lapse.state === 'deletion' && r.body.entitled === false, 'deleteAt in ' + Math.round((r.body.lapse.deleteAt - now) / DAY) + ' days');
r = await me(T.cancelled);check('ended plan with countdown: state deletion', r.body.lapse.state === 'deletion' && Math.abs(r.body.lapse.deleteAt - (now + 10 * DAY)) < 1000);
r = await me(T.neverPaid);check('never-paid free account: no lapse', r.body.lapse.state === 'none');
r = await me(T.lifetime); check('lifetime ignores a stale countdown', r.body.lapse.state === 'none' && r.body.entitled === true);

await worker.scheduled({}, env, { waitUntil: (p) => p });
await new Promise((res) => setTimeout(res, 300));
check('daily job: grace-over account gets a delete date 30 days after grace ended', Math.abs(row('locked').delete_at - (now - DAY + 30 * DAY)) < 2000);
check('daily job: account that lapsed 40 days ago is NOT deleted at once, it gets a 7-day warning window', hasUser('lockedold') && Math.abs(row('lockedold').delete_at - (now + 7 * DAY)) < 5000);
check('daily job: expired countdown -> account and data deleted', !hasUser('expired') && !hasItems('expired'));
check('daily job: still-counting-down account kept', hasUser('cancelled') && hasUser('locked'));
check('daily job: never-paid, lifetime, grandfathered accounts kept', hasUser('neverpaid') && hasUser('lifetime') && hasUser('gf'));
check('daily job: plan paid up in time is not deleted even with a stale date', hasUser('racing') && hasItems('racing'));
check('daily job: emails not set up -> stage still moves on (no endless retries)', row('locked').notice_stage === 1);
r = await me(T.expired);  check('old device of a deleted account is told 410 account_deleted', r.status === 410 && r.body.error === 'account_deleted');
r = await me('nobody-ever-had-this-token-123456'); check('unknown token is still a plain 401', r.status === 401 && r.body.error === 'bad_session');
raw.prepare("UPDATE users SET delete_at = ? WHERE id = 'u_cancelled'").run(now - 1);
await worker.scheduled({}, env, { waitUntil: (p) => p }); await new Promise((res) => setTimeout(res, 300));
check('a countdown that runs out later also deletes', !hasUser('cancelled'));
console.log(fail ? '\n' + fail + ' FAILED' : '\nALL PASSED'); process.exit(fail ? 1 : 0);
