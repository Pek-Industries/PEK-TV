import { adminCheck } from './admin.js';
import { json } from './config.js';
import { readJson } from './input.js';

// ---------------------------------------------------------------- news (the app's Updates screen)
// GET /v1/news is public and returns the newest 30 messages that have not expired. Posting needs the ADMIN_KEY.
export const NEWS_KINDS = ['news', 'update', 'coupon'];
export function cleanNewsText(v, max) {
    return String(v == null ? '' : v).replace(/\r\n?/g, '\n').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, ' ').replace(/\n{3,}/g, '\n\n').trim().slice(0, max);
}
export async function handleNewsList(env) {
    const now = Date.now();
    const rows = (await env.DB.prepare('SELECT id, created, kind, title, body, code, link FROM announcements WHERE expires = 0 OR expires > ? ORDER BY id DESC LIMIT 30').bind(now).all()).results || [];
    return json({ ok: true, items: rows.map(r => ({ id: r.id, created: r.created, kind: r.kind, title: r.title, body: r.body, code: r.code, link: r.link })) });
}
export async function handleNews(request, env, path) {
    const db = env.DB, now = Date.now(), DAY_MS = 24 * 3600 * 1000;
    const auth = await adminCheck(request, env, db, now);
    if (auth === 'limited') return json({ error: 'rate_limited' }, 429);
    if (auth !== 'ok') return json({ error: 'not_found' }, 404);
    const { body, err } = await readJson(request); if (err) return err;
    if (path === '/v1/news/post') {
        const title = cleanNewsText(body.title, 80).replace(/\n/g, ' ');
        if (!title) return json({ error: 'title_required' }, 400);
        const kind = NEWS_KINDS.indexOf(body.kind) >= 0 ? body.kind : 'news';
        const text = cleanNewsText(body.body, 1500);
        const code = cleanNewsText(body.code, 40).replace(/\s+/g, '');
        const link = /^https:\/\/[^\s<>"]{3,200}$/.test(String(body.link || '')) ? String(body.link) : '';
        const days = body.days == null ? 0 : Math.max(0, Math.min(365, Math.floor(Number(body.days) || 0)));   // 0 = never expires
        const r = await db.prepare('INSERT INTO announcements (created, expires, kind, title, body, code, link) VALUES (?, ?, ?, ?, ?, ?, ?)')
            .bind(now, days ? now + days * DAY_MS : 0, kind, title, text, code, link).run();
        return json({ ok: true, id: r.meta && r.meta.last_row_id, expiresInDays: days || null });
    }
    if (path === '/v1/news/list') {
        const rows = (await db.prepare('SELECT id, created, expires, kind, title, code FROM announcements ORDER BY id DESC LIMIT 100').all()).results || [];
        return json({ ok: true, items: rows.map(r => ({ id: r.id, created: new Date(r.created).toISOString(), expires: r.expires ? new Date(r.expires).toISOString() : null, live: !r.expires || r.expires > now, kind: r.kind, title: r.title, code: r.code })) });
    }
    if (path === '/v1/news/delete') {
        const id = Math.floor(Number(body.id));
        if (!(id > 0)) return json({ error: 'bad_id' }, 400);
        const r = await db.prepare('DELETE FROM announcements WHERE id = ?').bind(id).run();
        return r.meta && r.meta.changes ? json({ ok: true }) : json({ error: 'not_found' }, 404);
    }
    return json({ error: 'not_found' }, 404);
}
