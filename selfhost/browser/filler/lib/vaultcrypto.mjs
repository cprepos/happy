// Bitwarden client-side crypto, just the parts the filler needs, on node:crypto
// alone. Every decrypt checks the MAC before decrypting, and any EncString type
// other than 2 (AES-256-CBC + HMAC-SHA256) or 4 (RSA-2048-OAEP-SHA1) fails closed.
//
// Keys are 64-byte Buffers: 32 bytes encryption key, then 32 bytes MAC key
// (Bitwarden's SymmetricCryptoKey for AesCbc256_HmacSha256_B64).
import {
    createCipheriv, createDecipheriv, createHmac, createPrivateKey, pbkdf2Sync,
    privateDecrypt, publicEncrypt, randomBytes, timingSafeEqual, constants,
} from 'node:crypto';

export class VaultCryptoError extends Error {}

const b64 = (s) => {
    if (typeof s !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(s)) throw new VaultCryptoError('bad base64 in EncString');
    return Buffer.from(s, 'base64');
};

export function splitKey(key) {
    if (!Buffer.isBuffer(key) || key.length !== 64) throw new VaultCryptoError('a symmetric key must be 64 bytes');
    return { enc: key.subarray(0, 32), mac: key.subarray(32, 64) };
}

/** Parse "<type>.<data>" into {type, parts}. Only types 2 and 4 are accepted. */
export function parseEncString(s) {
    if (typeof s !== 'string') throw new VaultCryptoError('EncString missing');
    const dot = s.indexOf('.');
    if (dot < 1) throw new VaultCryptoError('EncString without a type');
    const type = s.slice(0, dot);
    const parts = s.slice(dot + 1).split('|');
    if (type === '2') {
        if (parts.length !== 3) throw new VaultCryptoError('type 2 EncString needs iv|data|mac');
        const [iv, data, mac] = parts.map(b64);
        if (iv.length !== 16 || mac.length !== 32 || data.length === 0 || data.length % 16) throw new VaultCryptoError('malformed type 2 EncString');
        return { type: 2, iv, data, mac };
    }
    if (type === '4') {
        if (parts.length !== 1) throw new VaultCryptoError('type 4 EncString has one part');
        return { type: 4, data: b64(parts[0]) };
    }
    throw new VaultCryptoError(`unsupported EncString type ${type.slice(0, 4)}`);
}

/** Decrypt a type 2 EncString with a 64-byte key. Returns a Buffer. */
export function decryptSym(encString, key) {
    const e = typeof encString === 'string' ? parseEncString(encString) : encString;
    if (e.type !== 2) throw new VaultCryptoError(`expected a type 2 EncString, got type ${e.type}`);
    const { enc, mac } = splitKey(key);
    const want = createHmac('sha256', mac).update(e.iv).update(e.data).digest();
    if (!timingSafeEqual(want, e.mac)) throw new VaultCryptoError('EncString MAC mismatch');
    const d = createDecipheriv('aes-256-cbc', enc, e.iv);
    return Buffer.concat([d.update(e.data), d.final()]);
}

export const decryptSymText = (s, key) => decryptSym(s, key).toString('utf8');

/** Encrypt to a type 2 EncString (tests, fixtures and enrollment checks). */
export function encryptSym(plain, key, iv = randomBytes(16)) {
    const { enc, mac } = splitKey(key);
    const c = createCipheriv('aes-256-cbc', enc, iv);
    const data = Buffer.concat([c.update(Buffer.isBuffer(plain) ? plain : Buffer.from(String(plain), 'utf8')), c.final()]);
    const m = createHmac('sha256', mac).update(iv).update(data).digest();
    return `2.${iv.toString('base64')}|${data.toString('base64')}|${m.toString('base64')}`;
}

/** Decrypt a type 4 EncString (RSA-OAEP, SHA-1) with a PKCS8 DER private key. */
export function decryptRsa(encString, pkcs8Der) {
    const e = typeof encString === 'string' ? parseEncString(encString) : encString;
    if (e.type !== 4) throw new VaultCryptoError(`expected a type 4 EncString, got type ${e.type}`);
    if (!Buffer.isBuffer(pkcs8Der)) throw new VaultCryptoError('no private key for a type 4 EncString');
    const key = createPrivateKey({ key: pkcs8Der, format: 'der', type: 'pkcs8' });
    try {
        return privateDecrypt({ key, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha1' }, e.data);
    } catch {
        throw new VaultCryptoError('RSA decrypt failed');
    }
}

export function encryptRsa(plain, publicKey) {
    const data = publicEncrypt({ key: publicKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha1' }, plain);
    return `4.${data.toString('base64')}`;
}

/** HKDF-Expand (RFC 5869 section 2.3) with SHA-256, as Bitwarden stretches the master key. */
export function hkdfExpand(prk, info, length = 32) {
    const out = [];
    let prev = Buffer.alloc(0);
    for (let i = 1; Buffer.concat(out).length < length; i++) {
        prev = createHmac('sha256', prk).update(prev).update(Buffer.isBuffer(info) ? info : Buffer.from(info, 'utf8')).update(Buffer.from([i])).digest();
        out.push(prev);
    }
    return Buffer.concat(out).subarray(0, length);
}

export const KDF_PBKDF2 = 0;

/** The master key (PBKDF2-SHA256 of the password, salted with the lowercased email). */
export function masterKey(password, email, iterations) {
    if (!Number.isInteger(iterations) || iterations < 100_000) throw new VaultCryptoError('PBKDF2 iterations below 100000 refused');
    return pbkdf2Sync(Buffer.from(password, 'utf8'), Buffer.from(String(email).trim().toLowerCase(), 'utf8'), iterations, 32, 'sha256');
}

/** The stretched master key (64 bytes) that decrypts profile.key. */
export function stretchMasterKey(mk) {
    return Buffer.concat([hkdfExpand(mk, 'enc', 32), hkdfExpand(mk, 'mac', 32)]);
}

/** The user key from profile.key. Bitwarden keys are 64 bytes; anything else fails closed. */
export function decryptUserKey(profileKey, stretched) {
    const k = decryptSym(profileKey, stretched);
    if (k.length !== 64) throw new VaultCryptoError(`user key is ${k.length} bytes, expected 64`);
    return k;
}

/** A 64-byte key from a type 2 EncString (item key) or type 4 (organization key). */
export function decryptKey(encString, { symKey, privateKey } = {}) {
    const e = parseEncString(encString);
    const k = e.type === 4 ? decryptRsa(e, privateKey) : decryptSym(e, symKey);
    if (k.length !== 64) throw new VaultCryptoError(`decrypted key is ${k.length} bytes, expected 64`);
    return k;
}
