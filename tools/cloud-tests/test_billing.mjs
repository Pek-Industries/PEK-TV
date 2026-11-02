import { makeDB } from './d1shim.mjs';
import billing from './billing.mjs';
import worker from './worker.mjs';
import { createHmac } from 'node:crypto';
const DAY = 86400000, now = Date.now(), SECRET = 'whsec_test';
const db = makeDB(), env = { DB: db, STRIPE_WEBHOOK_SECRET: SECRET, SITE_URL: 'https://pekindustries.com/pektv' };
let fail = 0; const check = (n, ok, x = '') => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (x ? '  (' + x + ')' : '')); if (!ok) fail++; };
await worker.fetch(new Request('https://x/v1/me'), env);                 // create the tables
const raw = db._raw;
raw.prepare("INSERT INTO users (id,email,pw,created,last_seen,verified,gf,username,plan,stripe_customer) VALUES ('u1','a@example.com','x',?,?,1,0,'ann','free','cus_1')").run(now, now);
const row = () => raw.prepare('SELECT * FROM users WHERE id = ?').get('u1');
let n = 0;
async function send(type, obj) {
  const body = JSON.stringify({ id: 'evt_' + (n++), type, data: { object: obj } }), t = Math.floor(Date.now() / 1000);
  const sig = createHmac('sha256', SECRET).update(t + '.' + body).digest('hex');
  const r = await billing.fetch(new Request('https://b/v1/billing/webhook', { method: 'POST', headers: { 'Stripe-Signature': `t=${t},v1=${sig}` }, body }), env);
  return r.status;
}
const sub = (end, extra = {}) => Object.assign({ id: 'sub_1', customer: 'cus_1', metadata: { user_id: 'u1' }, status: 'active', start_date: Math.floor((now - 60 * DAY) / 1000), current_period_end: Math.floor(end / 1000), items: { data: [{ price: { recurring: { interval: 'month' } } }] } }, extra);
check('new subscription accepted', await send('customer.subscription.created', sub(now + 30 * DAY)) === 200);
let u = row();
check('subscribed date saved from Stripe start date', u.plan === 'monthly' && Math.abs(u.plan_since - (now - 60 * DAY)) < 2000);
await send('customer.subscription.updated', sub(now + 60 * DAY, { start_date: Math.floor(now / 1000) }));
check('renewal keeps the original subscribed date', Math.abs(row().plan_since - (now - 60 * DAY)) < 2000);
raw.prepare("UPDATE users SET delete_at = ?, notice_stage = 2 WHERE id='u1'").run(now + DAY);
await send('customer.subscription.updated', sub(now + 90 * DAY));
check('paying clears any deletion countdown', row().delete_at === 0 && row().notice_stage === 0);
await send('customer.subscription.deleted', sub(now, { status: 'canceled' }));
u = row();
check('subscription ended: plan free and 30-day deletion countdown starts', u.plan === 'free' && u.delete_at > now + 29 * DAY && u.delete_at < now + 200 * DAY, 'in ' + Math.round((u.delete_at - now) / DAY) + ' days');
await send('customer.subscription.created', sub(now + 30 * DAY, { id: 'sub_2', start_date: Math.floor(now / 1000) }));
u = row();
check('resubscribing starts a new subscribed date and clears the countdown', u.plan === 'monthly' && Math.abs(u.plan_since - now) < 2000 && u.delete_at === 0);
raw.prepare("UPDATE users SET delete_at = ? WHERE id='u1'").run(now + 5 * DAY);
await send('checkout.session.completed', { mode: 'payment', payment_status: 'paid', client_reference_id: 'u1', customer: 'cus_1', metadata: { plan: 'lifetime', user_id: 'u1' } });
u = row();
check('lifetime purchase: plan lifetime, subscribed date kept from the subscription, countdown cleared', u.plan === 'lifetime' && Math.abs(u.plan_since - now) < 2000 && u.delete_at === 0);
console.log(fail ? '\n' + fail + ' FAILED' : '\nALL PASSED'); process.exit(fail ? 1 : 0);
