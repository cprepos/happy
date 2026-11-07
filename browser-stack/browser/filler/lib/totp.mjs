// TOTP (RFC 6238) for a vault item's totp field: a bare base32 secret or an
// otpauth://totp/ URI with algorithm SHA1/SHA256/SHA512, digits and period.
// Anything else (steam://, hotp) fails closed.
import { createHmac } from 'node:crypto';

export class TotpError extends Error {}

export function base32Decode(s) {
    const clean = String(s).replace(/[\s-]/g, '').replace(/=+$/, '').toUpperCase();
    if (!clean || !/^[A-Z2-7]+$/.test(clean)) throw new TotpError('TOTP secret is not base32');
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    let bits = 0, value = 0;
    const out = [];
    for (const ch of clean) {
        value = (value << 5) | alphabet.indexOf(ch);
        bits += 5;
        if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
    }
    return Buffer.from(out);
}

const ALGS = { SHA1: 'sha1', SHA256: 'sha256', SHA512: 'sha512' };

/** {key, algorithm, digits, period} from a vault totp field. */
export function parseTotp(field) {
    const s = String(field ?? '').trim();
    if (!s) throw new TotpError('no TOTP on this item');
    if (/^[a-z][a-z0-9+.-]*:/i.test(s) && !/^otpauth:/i.test(s)) throw new TotpError('unsupported TOTP scheme');
    if (!/^otpauth:/i.test(s)) return { key: base32Decode(s), algorithm: 'sha1', digits: 6, period: 30 };
    let u;
    try { u = new URL(s); } catch { throw new TotpError('bad otpauth URI'); }
    if (u.host.toLowerCase() !== 'totp') throw new TotpError('only otpauth://totp is supported');
    const p = u.searchParams;
    const algorithm = ALGS[(p.get('algorithm') || 'SHA1').toUpperCase()];
    if (!algorithm) throw new TotpError('unsupported TOTP algorithm');
    const digits = Number(p.get('digits') || 6);
    const period = Number(p.get('period') || 30);
    if (!Number.isInteger(digits) || digits < 6 || digits > 10) throw new TotpError('unsupported TOTP digits');
    if (!Number.isInteger(period) || period < 10 || period > 300) throw new TotpError('unsupported TOTP period');
    return { key: base32Decode(p.get('secret') || ''), algorithm, digits, period };
}

export function hotp(key, counter, algorithm = 'sha1', digits = 6) {
    const msg = Buffer.alloc(8);
    msg.writeBigUInt64BE(BigInt(counter));
    const h = createHmac(algorithm, key).update(msg).digest();
    const off = h[h.length - 1] & 0x0f;
    const bin = ((h[off] & 0x7f) << 24) | (h[off + 1] << 16) | (h[off + 2] << 8) | h[off + 3];
    return String(bin % 10 ** digits).padStart(digits, '0');
}

export function totpAt(spec, unixSeconds) {
    return hotp(spec.key, Math.floor(unixSeconds / spec.period), spec.algorithm, spec.digits);
}

/**
 * The current code, waiting for the next period when fewer than minLeftS seconds
 * are left (so the code is still valid when the site checks it).
 */
export async function currentTotp(field, { now = () => Date.now(), sleep = (ms) => new Promise((r) => setTimeout(r, ms)), minLeftS = 3 } = {}) {
    const spec = parseTotp(field);
    let t = now() / 1000;
    const left = spec.period - (t % spec.period);
    if (left < minLeftS) { await sleep(Math.ceil(left * 1000) + 50); t = now() / 1000; }
    return totpAt(spec, t);
}
