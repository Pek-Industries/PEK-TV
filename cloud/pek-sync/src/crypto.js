import { PBKDF2_ITERATIONS } from './config.js';

// ---------------------------------------------------------------- crypto helpers
export const enc = new TextEncoder();

export function hex(buf) { return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join(''); }
export function unhex(s) {
    const out = new Uint8Array(s.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
    return out;
}
export async function sha256Hex(text) { return hex(await crypto.subtle.digest('SHA-256', enc.encode(text))); }
export function randomHex(nBytes) { return hex(crypto.getRandomValues(new Uint8Array(nBytes))); }
export function randomToken() {
    const b = crypto.getRandomValues(new Uint8Array(32));
    let s = '';
    for (const x of b) s += String.fromCharCode(x);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export function sixDigits() {
    const buf = new Uint32Array(1);
    const limit = Math.floor(0x100000000 / 1000000) * 1000000;   // no modulo bias
    do { crypto.getRandomValues(buf); } while (buf[0] >= limit);
    return String(buf[0] % 1000000).padStart(6, '0');
}
export function sameString(a, b) {
    if (a.length !== b.length) return false;
    let d = 0;
    for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return d === 0;
}

export async function pbkdf2(password, saltBytes, iterations) {
    const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
    const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: saltBytes, iterations }, key, 256);
    return hex(bits);
}
// Stored as  pbkdf2$<iterations>$<salt hex>$<hash hex>
export async function hashPassword(password) {
    const salt = crypto.getRandomValues(new Uint8Array(16));
    return 'pbkdf2$' + PBKDF2_ITERATIONS + '$' + hex(salt) + '$' + await pbkdf2(password, salt, PBKDF2_ITERATIONS);
}
export async function checkPassword(password, stored) {
    const p = String(stored || '').split('$');
    if (p.length !== 4 || p[0] !== 'pbkdf2') return false;
    const got = await pbkdf2(password, unhex(p[2]), parseInt(p[1], 10));
    return sameString(got, p[3]);
}
let dummyHash = null;   // so "no such email" costs as much time as "wrong password"
export async function burnTime(password) {
    if (!dummyHash) dummyHash = await hashPassword('hesper-dummy');
    await checkPassword(password, dummyHash);
}
