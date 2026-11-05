import { test } from 'node:test';
import assert from 'node:assert/strict';
import { base32Decode, currentTotp, parseTotp, totpAt } from '../lib/totp.mjs';

// RFC 6238 appendix B: seeds are ASCII "12345678901234567890" repeated to the hash size.
const seed = (n) => Buffer.from('1234567890'.repeat(7).slice(0, n));
const VECTORS = [
    [59, '94287082', '46119246', '90693936'],
    [1111111109, '07081804', '68084774', '25091201'],
    [1111111111, '14050471', '67062674', '99943326'],
    [1234567890, '89005924', '91819424', '93441116'],
    [2000000000, '69279037', '90698825', '38618901'],
    [20000000000, '65353130', '77737706', '47863826'],
];

test('RFC 6238 vectors for SHA1, SHA256, SHA512', () => {
    for (const [t, s1, s256, s512] of VECTORS) {
        assert.equal(totpAt({ key: seed(20), algorithm: 'sha1', digits: 8, period: 30 }, t), s1);
        assert.equal(totpAt({ key: seed(32), algorithm: 'sha256', digits: 8, period: 30 }, t), s256);
        assert.equal(totpAt({ key: seed(64), algorithm: 'sha512', digits: 8, period: 30 }, t), s512);
    }
});

test('base32 and otpauth parsing', () => {
    assert.equal(base32Decode('GEZDGNBVGY3TQOJQ').toString(), '1234567890');
    assert.equal(base32Decode('gezd gnbv-gy3t qojq').toString(), '1234567890');
    const p = parseTotp('otpauth://totp/X:y?secret=GEZDGNBVGY3TQOJQ&algorithm=SHA512&digits=8&period=60');
    assert.deepEqual([p.algorithm, p.digits, p.period], ['sha512', 8, 60]);
    assert.equal(parseTotp('GEZDGNBVGY3TQOJQ').digits, 6);
    for (const bad of ['', 'steam://ABC', 'otpauth://hotp/x?secret=GEZDGNBV', 'otpauth://totp/x?secret=GEZD&algorithm=MD5', 'not base32 !!', 'otpauth://totp/x?secret=GEZD&digits=4']) {
        assert.throws(() => parseTotp(bad));
    }
});

test('waits for the next period when fewer than 3 s are left', async () => {
    let t = 29_000; // 1 s left in the period
    const slept = [];
    const code = await currentTotp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', { now: () => t, sleep: async (ms) => { slept.push(ms); t += ms; } });
    assert.equal(slept.length, 1);
    assert.equal(code, totpAt(parseTotp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'), 30.1));
    t = 5_000;
    await currentTotp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', { now: () => t, sleep: async () => { throw new Error('should not sleep'); } });
});
