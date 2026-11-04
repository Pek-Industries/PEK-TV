import { BUILTIN_PLUGINS, CLOCK_SLACK, json, MAX_PLUGIN_CHUNKS, MAX_PLUGIN_RAW, MAX_PLUGIN_TOTAL, MAX_PLUGINS, PLUGIN_CHUNK } from './config.js';
import { limited, readJson } from './input.js';

// ---------------------------------------------------------------- plugin backup handlers
export function goodPluginId(id) { return typeof id === 'string' && /^[a-z0-9][a-z0-9_-]{0,39}$/.test(id) && BUILTIN_PLUGINS.indexOf(id) === -1; }
export function goodFp(fp) { return typeof fp === 'string' && /^[a-f0-9]{8,64}$/.test(fp); }
export function shortText(v, max) { return typeof v === 'string' ? v.slice(0, max) : ''; }

export async function handlePluginList(env, acct) {
    const rows = await env.DB.prepare('SELECT id, name, version, size, fp, chunks, updated, deleted FROM plugins WHERE acct = ? ORDER BY id').bind(acct).all();
    const plugins = (rows.results || []).map(r => ({ id: r.id, name: r.name, version: r.version, size: r.size, fp: r.fp, chunks: r.chunks, updated: r.updated, deleted: r.deleted ? 1 : 0 }));
    return json({ ok: true, plugins });
}

export async function handlePluginChunk(request, env, acct) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const index = Number(body.index), total = Number(body.total);
    if (!goodPluginId(body.id) || !goodFp(body.fp)) return json({ error: 'bad_plugin' }, 400);
    if (!Number.isInteger(index) || !Number.isInteger(total) || total < 1 || total > MAX_PLUGIN_CHUNKS || index < 0 || index >= total) return json({ error: 'bad_plugin' }, 400);
    if (typeof body.data !== 'string' || !body.data.length || body.data.length > PLUGIN_CHUNK + 1000) return json({ error: 'too_large' }, 413);
    if (await limited(db, 'plugin:chunk:' + acct, 800, 3600 * 1000, now)) return json({ error: 'rate_limited' }, 429);
    await db.prepare('INSERT INTO plugin_chunks (acct, id, fp, idx, data, created) VALUES (?, ?, ?, ?, ?, ?) ' +
        'ON CONFLICT(acct, id, fp, idx) DO UPDATE SET data = excluded.data, created = excluded.created')
        .bind(acct, body.id, body.fp, index, body.data, now).run();
    return json({ ok: true });
}

export async function handlePluginCommit(request, env, acct) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const total = Number(body.total), size = Number(body.size), updated = Number(body.updated);
    if (!goodPluginId(body.id) || !goodFp(body.fp)) return json({ error: 'bad_plugin' }, 400);
    if (!Number.isInteger(total) || total < 1 || total > MAX_PLUGIN_CHUNKS) return json({ error: 'bad_plugin' }, 400);
    if (!Number.isFinite(size) || size < 1 || size > MAX_PLUGIN_RAW) return json({ error: 'too_large' }, 413);
    if (!Number.isFinite(updated) || updated <= 0) return json({ error: 'bad_plugin' }, 400);
    const when = Math.min(Math.floor(updated), now + CLOCK_SLACK);

    const have = await db.prepare('SELECT COUNT(*) AS n FROM plugin_chunks WHERE acct = ? AND id = ? AND fp = ?').bind(acct, body.id, body.fp).first();
    if (!have || have.n !== total) return json({ error: 'incomplete' }, 400);

    const cur = await db.prepare('SELECT updated, size FROM plugins WHERE acct = ? AND id = ?').bind(acct, body.id).first();
    if (cur && cur.updated >= when) {
        // the cloud already has a newer (or the same) copy; drop what was just uploaded
        await db.prepare('DELETE FROM plugin_chunks WHERE acct = ? AND id = ? AND fp = ? AND NOT EXISTS (SELECT 1 FROM plugins p WHERE p.acct = ? AND p.id = ? AND p.fp = ?)').bind(acct, body.id, body.fp, acct, body.id, body.fp).run();
        return json({ ok: true, stored: false });
    }
    const stats = await db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes FROM plugins WHERE acct = ? AND deleted = 0 AND id != ?').bind(acct, body.id).first();
    if (stats && (stats.n >= MAX_PLUGINS || stats.bytes + size > MAX_PLUGIN_TOTAL)) return json({ error: 'plugin_quota' }, 413);

    await db.batch([
        db.prepare('INSERT INTO plugins (acct, id, name, version, size, fp, chunks, updated, deleted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0) ' +
            'ON CONFLICT(acct, id) DO UPDATE SET name = excluded.name, version = excluded.version, size = excluded.size, fp = excluded.fp, ' +
            'chunks = excluded.chunks, updated = excluded.updated, deleted = 0')
            .bind(acct, body.id, shortText(body.name, 80) || body.id, shortText(body.version, 40), Math.floor(size), body.fp, total, when),
        db.prepare('DELETE FROM plugin_chunks WHERE acct = ? AND id = ? AND fp != ?').bind(acct, body.id, body.fp)
    ]);
    return json({ ok: true, stored: true });
}

export async function handlePluginGetChunk(url, env, acct) {
    const id = url.searchParams.get('id'), fp = url.searchParams.get('fp'), i = Number(url.searchParams.get('i'));
    if (!goodPluginId(id) || !goodFp(fp) || !Number.isInteger(i) || i < 0) return json({ error: 'bad_plugin' }, 400);
    const row = await env.DB.prepare('SELECT data FROM plugin_chunks WHERE acct = ? AND id = ? AND fp = ? AND idx = ?').bind(acct, id, fp, i).first();
    if (!row) return json({ error: 'not_found' }, 404);
    return json({ ok: true, data: row.data });
}

export async function handlePluginDelete(request, env, acct) {
    const { body, err } = await readJson(request); if (err) return err;
    const db = env.DB, now = Date.now();
    const updated = Number(body.updated);
    if (!goodPluginId(body.id) || !Number.isFinite(updated) || updated <= 0) return json({ error: 'bad_plugin' }, 400);
    const when = Math.min(Math.floor(updated), now + CLOCK_SLACK);
    const cur = await db.prepare('SELECT updated FROM plugins WHERE acct = ? AND id = ?').bind(acct, body.id).first();
    if (cur && cur.updated >= when) return json({ ok: true, stored: false });   // a newer backup exists
    // keep a tiny "deleted" marker so other devices learn about the removal; the files are dropped
    await db.batch([
        db.prepare("INSERT INTO plugins (acct, id, name, version, size, fp, chunks, updated, deleted) VALUES (?, ?, '', '', 0, '', 0, ?, 1) " +
            "ON CONFLICT(acct, id) DO UPDATE SET name = '', version = '', size = 0, fp = '', chunks = 0, updated = excluded.updated, deleted = 1")
            .bind(acct, body.id, when),
        db.prepare('DELETE FROM plugin_chunks WHERE acct = ? AND id = ?').bind(acct, body.id)
    ]);
    return json({ ok: true, stored: true });
}
