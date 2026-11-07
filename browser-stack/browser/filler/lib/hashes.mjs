// Hash verification for /v1/vault/compare, in plain JavaScript (node 22 has
// neither argon2 nor bcrypt): sha256 and sha512 with an optional salt prefix,
// bcrypt ($2a$, $2b$, $2y$) and argon2 (argon2d, argon2i, argon2id; versions
// 0x10 and 0x13). Verify only: nothing here returns a hash of a stored value,
// and compareValue answers true or false. Cost parameters are capped so a
// compare cannot tie up the filler.
import { createHash, timingSafeEqual } from 'node:crypto';

export class HashError extends Error {
    constructor(message) { super(message); this.status = 400; }
}

export const LIMITS = Object.freeze({ bcryptCost: 14, argon2MemKiB: 65536, argon2Time: 10, argon2Work: 196608, argon2Lanes: 16 });

// ---------------------------------------------------------------- blake2b
const M64 = (1n << 64n) - 1n;
const B2_IV = [
    0x6a09e667f3bcc908n, 0xbb67ae8584caa73bn, 0x3c6ef372fe94f82bn, 0xa54ff53a5f1d36f1n,
    0x510e527fade682d1n, 0x9b05688c2b3e6c1fn, 0x1f83d9abfb41bd6bn, 0x5be0cd19137e2179n,
];
const SIGMA = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
];
const rotr = (x, n) => ((x >> n) | (x << (64n - n))) & M64;

/** BLAKE2b with an output length of 1..64 bytes (unkeyed). */
export function blake2b(data, outLen = 64) {
    if (!(outLen >= 1 && outLen <= 64)) throw new RangeError('blake2b output length');
    const msg = Buffer.from(data);
    const h = B2_IV.slice();
    h[0] ^= 0x01010000n ^ BigInt(outLen);
    const blocks = Math.max(1, Math.ceil(msg.length / 128));
    const v = new Array(16); const m = new Array(16);
    for (let b = 0; b < blocks; b++) {
        const last = b === blocks - 1;
        const chunk = Buffer.alloc(128);
        msg.copy(chunk, 0, b * 128, Math.min(msg.length, b * 128 + 128));
        for (let i = 0; i < 16; i++) m[i] = chunk.readBigUInt64LE(i * 8);
        const t = BigInt(last ? msg.length : (b + 1) * 128);
        for (let i = 0; i < 8; i++) { v[i] = h[i]; v[i + 8] = B2_IV[i]; }
        v[12] ^= t & M64; v[13] ^= t >> 64n;
        if (last) v[14] ^= M64;
        const G = (a, bb, c, d, x, y) => {
            v[a] = (v[a] + v[bb] + x) & M64; v[d] = rotr(v[d] ^ v[a], 32n);
            v[c] = (v[c] + v[d]) & M64; v[bb] = rotr(v[bb] ^ v[c], 24n);
            v[a] = (v[a] + v[bb] + y) & M64; v[d] = rotr(v[d] ^ v[a], 16n);
            v[c] = (v[c] + v[d]) & M64; v[bb] = rotr(v[bb] ^ v[c], 63n);
        };
        for (let r = 0; r < 12; r++) {
            const s = SIGMA[r % 10];
            G(0, 4, 8, 12, m[s[0]], m[s[1]]); G(1, 5, 9, 13, m[s[2]], m[s[3]]);
            G(2, 6, 10, 14, m[s[4]], m[s[5]]); G(3, 7, 11, 15, m[s[6]], m[s[7]]);
            G(0, 5, 10, 15, m[s[8]], m[s[9]]); G(1, 6, 11, 12, m[s[10]], m[s[11]]);
            G(2, 7, 8, 13, m[s[12]], m[s[13]]); G(3, 4, 9, 14, m[s[14]], m[s[15]]);
        }
        for (let i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
    }
    const out = Buffer.alloc(64);
    for (let i = 0; i < 8; i++) out.writeBigUInt64LE(h[i], i * 8);
    return out.subarray(0, outLen);
}

// ---------------------------------------------------------------- argon2
const le32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32LE(n >>> 0); return b; };

/** Argon2's variable-length hash H'. */
function hPrime(T, X) {
    const input = Buffer.concat([le32(T), X]);
    if (T <= 64) return blake2b(input, T);
    const r = Math.ceil(T / 32) - 2;
    const parts = []; let V = blake2b(input, 64);
    parts.push(V.subarray(0, 32));
    for (let i = 1; i < r; i++) { V = blake2b(V, 64); parts.push(V.subarray(0, 32)); }
    parts.push(blake2b(V, T - 32 * r));
    return Buffer.concat(parts);
}

// 32x32 -> 64-bit product, as [lo, hi].
function mul32(a, b) {
    const a0 = a & 0xffff, a1 = a >>> 16, b0 = b & 0xffff, b1 = b >>> 16;
    const mid = a1 * b0 + a0 * b1 + ((a0 * b0) >>> 16);
    return [Math.imul(a, b) >>> 0, (a1 * b1 + Math.floor(mid / 65536)) >>> 0];
}

// The BlaMka round on 16 64-bit words held as lo/hi pairs in w, at word
// indices idx (each word i is w[2i], w[2i+1]).
function blamkaG(w, a, b, c, d) {
    // x = x + y + 2*lo(x)*lo(y)
    const fb = (x, y) => {
        const [pl, ph] = mul32(w[2 * x], w[2 * y]);
        const ml = (pl << 1) >>> 0, mh = ((ph << 1) | (pl >>> 31)) >>> 0;
        let lo = w[2 * x] + w[2 * y]; let hi = w[2 * x + 1] + w[2 * y + 1] + (lo > 0xffffffff ? 1 : 0); lo >>>= 0;
        const lo2 = lo + ml; hi = (hi + mh + (lo2 > 0xffffffff ? 1 : 0)) >>> 0;
        w[2 * x] = lo2 >>> 0; w[2 * x + 1] = hi;
    };
    const xr = (x, y, n) => { // w[x] = rotr64(w[x] ^ w[y], n)
        const l = (w[2 * x] ^ w[2 * y]) >>> 0, h = (w[2 * x + 1] ^ w[2 * y + 1]) >>> 0;
        if (n === 32) { w[2 * x] = h; w[2 * x + 1] = l; return; }
        if (n === 63) { w[2 * x] = ((l << 1) | (h >>> 31)) >>> 0; w[2 * x + 1] = ((h << 1) | (l >>> 31)) >>> 0; return; }
        w[2 * x] = ((l >>> n) | (h << (32 - n))) >>> 0; w[2 * x + 1] = ((h >>> n) | (l << (32 - n))) >>> 0;
    };
    fb(a, b); xr(d, a, 32); fb(c, d); xr(b, c, 24); fb(a, b); xr(d, a, 16); fb(c, d); xr(b, c, 63);
}

const ROW_IDX = []; const COL_IDX = [];
for (let i = 0; i < 8; i++) {
    ROW_IDX.push(Array.from({ length: 16 }, (_, k) => 16 * i + k));
    const col = [];
    for (let k = 0; k < 8; k++) col.push(2 * i + 16 * k, 2 * i + 16 * k + 1);
    COL_IDX.push(col);
}
function roundP(w, idx) {
    const v = idx;
    blamkaG(w, v[0], v[4], v[8], v[12]); blamkaG(w, v[1], v[5], v[9], v[13]);
    blamkaG(w, v[2], v[6], v[10], v[14]); blamkaG(w, v[3], v[7], v[11], v[15]);
    blamkaG(w, v[0], v[5], v[10], v[15]); blamkaG(w, v[1], v[6], v[11], v[12]);
    blamkaG(w, v[2], v[7], v[8], v[13]); blamkaG(w, v[3], v[4], v[9], v[14]);
}

const R = new Uint32Array(256); const TMP = new Uint32Array(256);
/** next = G(prev, ref) (xor next when withXor); blocks are 256-word views. */
function fillBlock(prev, ref, next, withXor) {
    for (let i = 0; i < 256; i++) R[i] = prev[i] ^ ref[i];
    for (let i = 0; i < 256; i++) TMP[i] = withXor ? R[i] ^ next[i] : R[i];
    for (let i = 0; i < 8; i++) roundP(R, ROW_IDX[i]);
    for (let i = 0; i < 8; i++) roundP(R, COL_IDX[i]);
    for (let i = 0; i < 256; i++) next[i] = TMP[i] ^ R[i];
}

const TYPES = { argon2d: 0, argon2i: 1, argon2id: 2 };

/** Raw argon2: returns the tag (Buffer). */
export function argon2Raw({ type, version = 0x13, password, salt, memKiB, time, lanes, tagLen, secret = Buffer.alloc(0), ad = Buffer.alloc(0) }) {
    const y = TYPES[type];
    if (y === undefined) throw new HashError('unknown argon2 type');
    const pw = Buffer.from(password); const sl = Buffer.from(salt);
    const H0 = blake2b(Buffer.concat([
        le32(lanes), le32(tagLen), le32(memKiB), le32(time), le32(version), le32(y),
        le32(pw.length), pw, le32(sl.length), sl, le32(secret.length), secret, le32(ad.length), ad,
    ]), 64);
    const mBlocks = 4 * lanes * Math.floor(memKiB / (4 * lanes));
    const laneLen = mBlocks / lanes; const segLen = laneLen / 4;
    const mem = new Uint32Array(mBlocks * 256);
    const block = (i) => mem.subarray(i * 256, i * 256 + 256);
    const fromBytes = (buf, dst) => { for (let i = 0; i < 256; i++) dst[i] = buf.readUInt32LE(i * 4); };
    for (let l = 0; l < lanes; l++) {
        fromBytes(hPrime(1024, Buffer.concat([H0, le32(0), le32(l)])), block(l * laneLen));
        fromBytes(hPrime(1024, Buffer.concat([H0, le32(1), le32(l)])), block(l * laneLen + 1));
    }
    const zero = new Uint32Array(256); const input = new Uint32Array(256); const addr = new Uint32Array(256);
    for (let pass = 0; pass < time; pass++) {
        for (let slice = 0; slice < 4; slice++) {
            for (let lane = 0; lane < lanes; lane++) {
                const indep = y === 1 || (y === 2 && pass === 0 && slice < 2);
                const nextAddresses = () => {
                    input[12] = (input[12] + 1) >>> 0; // counter, word 6 (lo)
                    fillBlock(zero, input, addr, false);
                    fillBlock(zero, addr, addr, false);
                };
                if (indep) {
                    input.fill(0);
                    input[0] = pass; input[2] = lane; input[4] = slice; input[6] = mBlocks; input[8] = time; input[10] = y;
                }
                let start = 0;
                if (pass === 0 && slice === 0) { start = 2; if (indep) nextAddresses(); }
                let cur = lane * laneLen + slice * segLen + start;
                let prev = cur % laneLen === 0 ? cur + laneLen - 1 : cur - 1;
                for (let i = start; i < segLen; i++, cur++, prev++) {
                    if (cur % laneLen === 1) prev = cur - 1;
                    let j1; let j2;
                    if (indep) {
                        if (i % 128 === 0) nextAddresses();
                        j1 = addr[2 * (i % 128)]; j2 = addr[2 * (i % 128) + 1];
                    } else {
                        j1 = mem[prev * 256]; j2 = mem[prev * 256 + 1];
                    }
                    const refLane = pass === 0 && slice === 0 ? lane : j2 % lanes;
                    const same = refLane === lane;
                    let area;
                    if (pass === 0) {
                        if (slice === 0) area = i - 1;
                        else area = same ? slice * segLen + i - 1 : slice * segLen + (i === 0 ? -1 : 0);
                    } else {
                        area = same ? laneLen - segLen + i - 1 : laneLen - segLen + (i === 0 ? -1 : 0);
                    }
                    const x = mul32(j1, j1)[1];
                    const rel = area - 1 - mul32(area, x)[1];
                    const startPos = pass !== 0 && slice !== 3 ? (slice + 1) * segLen : 0;
                    const refIdx = (startPos + rel) % laneLen;
                    fillBlock(block(prev), block(refLane * laneLen + refIdx), block(cur), pass !== 0 && version === 0x13);
                }
            }
        }
    }
    const C = new Uint32Array(256);
    for (let l = 0; l < lanes; l++) { const b = block(l * laneLen + laneLen - 1); for (let i = 0; i < 256; i++) C[i] ^= b[i]; }
    const cb = Buffer.alloc(1024);
    for (let i = 0; i < 256; i++) cb.writeUInt32LE(C[i], i * 4);
    mem.fill(0);
    return hPrime(tagLen, cb);
}

const b64d = (s) => {
    if (!/^[A-Za-z0-9+/]+$/.test(s)) throw new HashError('argon2 digest: bad base64');
    return Buffer.from(s, 'base64');
};

/** {type, version, memKiB, time, lanes, salt, hash} from a PHC string, within LIMITS. */
export function parseArgon2(phc) {
    const m = /^\$(argon2id|argon2i|argon2d)\$(?:v=(\d+)\$)?m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$/.exec(String(phc));
    if (!m) throw new HashError('argon2 digest must be a PHC string ($argon2id$v=19$m=…,t=…,p=…$salt$hash)');
    const version = m[2] === undefined ? 0x10 : Number(m[2]);
    if (version !== 0x10 && version !== 0x13) throw new HashError('argon2 version must be 16 or 19');
    const memKiB = Number(m[3]); const time = Number(m[4]); const lanes = Number(m[5]);
    const salt = b64d(m[6]); const hash = b64d(m[7]);
    if (lanes < 1 || lanes > LIMITS.argon2Lanes) throw new HashError(`argon2 p must be 1..${LIMITS.argon2Lanes}`);
    if (time < 1 || time > LIMITS.argon2Time) throw new HashError(`argon2 t must be 1..${LIMITS.argon2Time}`);
    if (memKiB < 8 * lanes || memKiB > LIMITS.argon2MemKiB) throw new HashError(`argon2 m must be 8*p..${LIMITS.argon2MemKiB}`);
    if (memKiB * time > LIMITS.argon2Work) throw new HashError(`argon2 m*t must be at most ${LIMITS.argon2Work}`);
    if (salt.length < 8 || salt.length > 64) throw new HashError('argon2 salt must be 8..64 bytes');
    if (hash.length < 4 || hash.length > 64) throw new HashError('argon2 hash must be 4..64 bytes');
    return { type: m[1], version, memKiB, time, lanes, salt, hash };
}

// ---------------------------------------------------------------- bcrypt
// Blowfish's initial P-array and S-boxes are the fractional hex digits of pi:
// 18 + 4*256 = 1042 words, computed once (Machin's formula, BigInt).
let BF_INIT = null;
function blowfishInit() {
    if (BF_INIT) return BF_INIT;
    const words = 1042; const bits = BigInt(words * 32 + 64);
    const one = 1n << bits;
    const atanInv = (x) => {
        const xx = x * x; let term = one / x; let sum = term; let n = 1n; let sign = -1n;
        while (term !== 0n) { term /= xx; n += 2n; sum += sign * (term / n); sign = -sign; }
        return sum;
    };
    const pi = 16n * atanInv(5n) - 4n * atanInv(239n);
    let frac = (pi & (one - 1n)) >> 64n; // drop the guard bits
    const out = new Uint32Array(words);
    for (let i = words - 1; i >= 0; i--) { out[i] = Number(frac & 0xffffffffn); frac >>= 32n; }
    if (out[0] !== 0x243f6a88 || out[18] !== 0xd1310ba6 || out[words - 1] !== 0x3ac372e6) throw new Error('blowfish constants self-check failed');
    BF_INIT = out;
    return out;
}

const BC64 = './ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
function bcDecode(s, n) {
    const out = []; let acc = 0; let bitsN = 0;
    for (const ch of s) {
        const v = BC64.indexOf(ch);
        if (v < 0) throw new HashError('bcrypt digest: bad character');
        acc = (acc << 6) | v; bitsN += 6;
        if (bitsN >= 8) { bitsN -= 8; out.push((acc >> bitsN) & 0xff); }
        if (out.length === n) break;
    }
    return Buffer.from(out);
}
function bcEncode(buf) {
    let s = ''; let acc = 0; let bitsN = 0;
    for (const b of buf) { acc = (acc << 8) | b; bitsN += 8; while (bitsN >= 6) { bitsN -= 6; s += BC64[(acc >> bitsN) & 63]; } acc &= 0xff; }
    if (bitsN) s += BC64[(acc << (6 - bitsN)) & 63];
    return s;
}

function bcryptRaw(password, salt, cost) {
    const init = blowfishInit();
    const P = init.slice(0, 18); const S = init.slice(18);
    const key = Buffer.concat([Buffer.from(password, 'utf8'), Buffer.from([0])]).subarray(0, 72);
    const F = (x) => ((((S[x >>> 24] + S[256 + ((x >>> 16) & 0xff)]) >>> 0) ^ S[512 + ((x >>> 8) & 0xff)]) + S[768 + (x & 0xff)]) >>> 0;
    const lr = new Uint32Array(2);
    const encipher = () => {
        let l = lr[0]; let r = lr[1];
        l = (l ^ P[0]) >>> 0;
        for (let i = 1; i <= 16; i += 2) { r = (r ^ F(l) ^ P[i]) >>> 0; l = (l ^ F(r) ^ P[i + 1]) >>> 0; }
        lr[0] = (r ^ P[17]) >>> 0; lr[1] = l;
    };
    const stream = (data) => { let pos = 0; return () => { let w = 0; for (let i = 0; i < 4; i++) { w = ((w << 8) | data[pos]) >>> 0; pos = (pos + 1) % data.length; } return w; }; };
    const expand = (k, s) => {
        const ks = stream(k); for (let i = 0; i < 18; i++) P[i] = (P[i] ^ ks()) >>> 0;
        const ss = s ? stream(s) : null;
        lr[0] = 0; lr[1] = 0;
        const step = () => { if (ss) { lr[0] = (lr[0] ^ ss()) >>> 0; lr[1] = (lr[1] ^ ss()) >>> 0; } encipher(); };
        for (let i = 0; i < 18; i += 2) { step(); P[i] = lr[0]; P[i + 1] = lr[1]; }
        for (let i = 0; i < 1024; i += 2) { step(); S[i] = lr[0]; S[i + 1] = lr[1]; }
    };
    expand(key, salt);
    for (let i = 0, n = 2 ** cost; i < n; i++) { expand(key, null); expand(salt, null); }
    const ctext = Buffer.from('OrpheanBeholderScryDoubt');
    const cd = new Uint32Array(6);
    for (let i = 0; i < 6; i++) cd[i] = ctext.readUInt32BE(i * 4);
    for (let i = 0; i < 64; i++) for (let j = 0; j < 6; j += 2) { lr[0] = cd[j]; lr[1] = cd[j + 1]; encipher(); cd[j] = lr[0]; cd[j + 1] = lr[1]; }
    const out = Buffer.alloc(24);
    for (let i = 0; i < 6; i++) out.writeUInt32BE(cd[i], i * 4);
    key.fill(0); P.fill(0); S.fill(0);
    return out.subarray(0, 23);
}

/** {prefix, cost, salt, hash} from a $2a$/$2b$/$2y$ string, within LIMITS. */
export function parseBcrypt(digest) {
    const m = /^\$(2[aby])\$(\d{2})\$([./A-Za-z0-9]{22})([./A-Za-z0-9]{31})$/.exec(String(digest));
    if (!m) throw new HashError('bcrypt digest must look like $2b$12$<22 salt chars><31 hash chars>');
    const cost = Number(m[2]);
    if (cost < 4 || cost > LIMITS.bcryptCost) throw new HashError(`bcrypt cost must be 4..${LIMITS.bcryptCost}`);
    return { prefix: m[1], cost, salt: bcDecode(m[3], 16), hash: m[4] };
}

/** The bcrypt string for a password under a setting ("$2b$12$<salt>"); tests use it against crypt(3). */
export function bcryptHash(password, setting) {
    const m = /^\$(2[aby])\$(\d{2})\$([./A-Za-z0-9]{22})/.exec(String(setting));
    if (!m) throw new HashError('bad bcrypt setting');
    const salt = bcDecode(m[3], 16);
    return `$${m[1]}$${m[2]}$${bcEncode(salt)}${bcEncode(bcryptRaw(password, salt, Number(m[2])))}`;
}

// ---------------------------------------------------------------- compare
const eq = (a, b) => a.length === b.length && timingSafeEqual(a, b);

export const ALGOS = ['sha256', 'sha512', 'bcrypt', 'argon2'];

/**
 * Whether value hashes to digest under algo. sha256/sha512: digest is hex of
 * hash(salt + value) (salt optional, a plain string prefix). bcrypt: a
 * $2a$/$2b$/$2y$ string. argon2: a PHC string. A malformed digest throws
 * HashError (400); salt is only for sha256/sha512.
 */
export function compareValue(value, { algo, digest, salt } = {}) {
    if (typeof value !== 'string') return false;
    if (typeof digest !== 'string' || digest.length > 512) throw new HashError('digest must be a string');
    if (salt !== undefined && algo !== 'sha256' && algo !== 'sha512') throw new HashError('salt is only for sha256 and sha512 (bcrypt and argon2 carry their own)');
    if (algo === 'sha256' || algo === 'sha512') {
        const hexLen = algo === 'sha256' ? 64 : 128;
        if (!new RegExp(`^[0-9a-fA-F]{${hexLen}}$`).test(digest)) throw new HashError(`${algo} digest must be ${hexLen} hex characters`);
        if (salt !== undefined && (typeof salt !== 'string' || salt.length > 256)) throw new HashError('salt must be a string of at most 256 characters');
        const got = createHash(algo).update(salt ?? '', 'utf8').update(value, 'utf8').digest();
        return eq(got, Buffer.from(digest, 'hex'));
    }
    if (algo === 'bcrypt') {
        const p = parseBcrypt(digest);
        const got = Buffer.from(bcEncode(bcryptRaw(value, p.salt, p.cost)));
        return eq(got, Buffer.from(p.hash));
    }
    if (algo === 'argon2') {
        const p = parseArgon2(digest);
        const got = argon2Raw({ type: p.type, version: p.version, password: Buffer.from(value, 'utf8'), salt: p.salt, memKiB: p.memKiB, time: p.time, lanes: p.lanes, tagLen: p.hash.length });
        return eq(got, p.hash);
    }
    throw new HashError(`algo must be one of ${ALGOS.join(', ')}`);
}
