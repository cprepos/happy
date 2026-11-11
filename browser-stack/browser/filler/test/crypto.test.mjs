import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import {
    decryptKey, decryptRsa, decryptSym, decryptSymText, decryptUserKey, encryptRsa, encryptSym,
    hkdfExpand, masterKey, parseEncString, stretchMasterKey, VaultCryptoError,
} from '../lib/providers/vaultwarden/vaultcrypto.mjs';

test('type 2 round trip, unicode included', () => {
    const k = randomBytes(64);
    for (const v of ['', 'x', 'pässwörd 🔑', 'a'.repeat(1000)]) assert.equal(decryptSymText(encryptSym(v, k), k), v);
});

test('a tampered MAC, IV or ciphertext is rejected before decrypting', () => {
    const k = randomBytes(64);
    const s = encryptSym('secret', k);
    const [iv, data, mac] = s.slice(2).split('|');
    const flip = (b) => { const x = Buffer.from(b, 'base64'); x[0] ^= 1; return x.toString('base64'); };
    for (const bad of [`2.${flip(iv)}|${data}|${mac}`, `2.${iv}|${flip(data)}|${mac}`, `2.${iv}|${data}|${flip(mac)}`]) {
        assert.throws(() => decryptSym(bad, k), /MAC mismatch/);
    }
    assert.throws(() => decryptSym(s, randomBytes(64)), /MAC mismatch/);
});

test('unknown or malformed EncString types fail closed', () => {
    for (const bad of ['0.abc|def', '1.a|b', '3.abcd', '5.x', '6.x', 'nodot', '2.a|b', '2.!!|!!|!!', null, 42]) {
        assert.throws(() => parseEncString(bad), VaultCryptoError);
    }
});

test('RSA-OAEP-SHA1 org key unwrap', () => {
    const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const der = privateKey.export({ format: 'der', type: 'pkcs8' });
    const orgKey = randomBytes(64);
    assert.deepEqual(decryptKey(encryptRsa(orgKey, publicKey), { privateKey: der }), orgKey);
    assert.throws(() => decryptRsa(encryptRsa(orgKey, publicKey), undefined), VaultCryptoError);
    assert.throws(() => decryptKey(encryptSym(randomBytes(32), randomBytes(64)), { symKey: randomBytes(64) }), VaultCryptoError);
});

test('HKDF-Expand matches RFC 5869 test case 1 (expand step)', () => {
    const prk = Buffer.from('077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5', 'hex');
    const info = Buffer.from('f0f1f2f3f4f5f6f7f8f9', 'hex');
    assert.equal(hkdfExpand(prk, info, 42).toString('hex'),
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865');
});

test('master key -> stretched key -> user key, as a client would', () => {
    const email = ' Agent@Vault.Test ';
    const mk = masterKey('pw', email, 100_000);
    const stretched = stretchMasterKey(mk);
    const userKey = randomBytes(64);
    assert.deepEqual(decryptUserKey(encryptSym(userKey, stretched), stretched), userKey);
    // The salt is the trimmed, lowercased email.
    assert.deepEqual(masterKey('pw', 'agent@vault.test', 100_000), mk);
    assert.throws(() => masterKey('pw', email, 5000), /iterations/);
    assert.throws(() => decryptUserKey(encryptSym(randomBytes(32), stretched), stretched), /64/);
});
