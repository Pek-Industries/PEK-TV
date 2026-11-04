import { INVITE_ALPHABET, VERIFY_TTL } from './config.js';
import { sha256Hex } from './crypto.js';

// ---------------------------------------------------------------- invite codes (single use)
// A code looks like PEK-7K3QX-9MLTA. Only its SHA-256 hash is stored, so the code can't be read back from the database.
// Life of a code: unused -> held (while its owner confirms their email, 30 minutes, renewed by "resend") -> used (for good).
export function inviteOnly(env) {
    const v = String(env.INVITE_ONLY == null ? '' : env.INVITE_ONLY).trim().toLowerCase();
    return v === '1' || v === 'true' || v === 'on' || v === 'yes';
}
export function normInvite(v) {                       // "pek-7k3qx-9mlta", "PEK7K3QX9MLTA" and "7K3QX9MLTA" are the same code
    let n = String(v == null ? '' : v).toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (n.length === 13 && n.indexOf('PEK') === 0) n = n.slice(3);
    return n;
}
export async function inviteHash(v) {
    const n = normInvite(v);
    return n.length === 10 ? sha256Hex('pek:invite:' + n) : null;
}
export function newInviteCode() {
    let s = '';
    while (s.length < 10) {                    // rejection sampling: no bias towards the first letters
        const b = crypto.getRandomValues(new Uint8Array(16));
        for (const x of b) if (x < 248 && s.length < 10) s += INVITE_ALPHABET[x % 31];
    }
    return 'PEK-' + s.slice(0, 5) + '-' + s.slice(5);
}
// Holds an unused, unexpired code for this account. One UPDATE decides it, so two people can never get the same code.
export async function holdInvite(db, hash, userId, now) {
    await db.prepare('UPDATE invites SET reserved_by = NULL, reserved_until = 0 WHERE reserved_by = ? AND used_by IS NULL AND hash <> ?').bind(userId, hash).run();
    const r = await db.prepare('UPDATE invites SET reserved_by = ?, reserved_until = ? WHERE hash = ? AND used_by IS NULL AND (expires = 0 OR expires > ?) AND (reserved_by IS NULL OR reserved_until < ? OR reserved_by = ?)')
        .bind(userId, now + VERIFY_TTL, hash, now, now, userId).run();
    return !!(r.meta && r.meta.changes);
}
// The confirmed email burns the code for good. Returns false when this account does not hold one (it must not be confirmed then).
export async function useInvite(env, db, user, now) {
    if (!inviteOnly(env) || user.verified || user.gf) return true;
    const r = await db.prepare('UPDATE invites SET used_by = ?, used_at = ?, reserved_by = NULL, reserved_until = 0 WHERE reserved_by = ? AND used_by IS NULL').bind(user.id, now, user.id).run();
    return !!(r.meta && r.meta.changes);
}
