// The compare route's verifiers, checked against outside implementations:
// node's blake2b512 and python's hashlib.blake2b, crypt(3) (libxcrypt) for
// bcrypt, and argon2-cffi for argon2. Test strings only, no real values.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { blake2b, bcryptHash, compareValue, parseArgon2, parseBcrypt, HashError } from '../lib/hashes.mjs';
import { CLASSES, generatePassword, checkSpec } from '../lib/generate.mjs';

test('blake2b matches node and python for every output length tried', () => {
    assert.equal(blake2b('abc', 1).toString('hex'), '6b');
    assert.equal(blake2b('abc', 32).toString('hex'), 'bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319');
    assert.equal(blake2b('abc', 48).toString('hex'), '6f56a82c8e7ef526dfe182eb5212f7db9df1317e57815dbda46083fc30f54ee6c66ba83be64b302d7cba6ce15bb556f4');
    for (const n of [0, 1, 127, 128, 129, 300]) {
        const d = randomBytes(n);
        assert.ok(blake2b(d, 64).equals(createHash('blake2b512').update(d).digest()), `len ${n}`);
    }
});

test('bcrypt matches crypt(3)', () => {
    assert.equal(bcryptHash('U*U', '$2a$05$CCCCCCCCCCCCCCCCCCCCC.'), '$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW');
    assert.equal(bcryptHash('', '$2b$04$abcdefghijklmnopqrstuu'), '$2b$04$abcdefghijklmnopqrstuubyCG3zY1GIXMyxfivm.ClDiInHzxjiq');
    assert.equal(bcryptHash('héllo wörld', '$2b$06$0123456789abcdefghijkl'), '$2b$06$0123456789abcdefghijkeO0cy/PMfMQUZWwe7yFyXFwEMbLNRKsS');
    // Past 72 bytes nothing counts.
    assert.equal(bcryptHash('x'.repeat(80), '$2b$04$ABCDEFGHIJKLMNOPQRSTUu'), '$2b$04$ABCDEFGHIJKLMNOPQRSTUuuPMGVdMuE6yqNwaDAANxW.7cK/ZbrX6');
    assert.equal(compareValue('U*U', { algo: 'bcrypt', digest: '$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW' }), true);
    assert.equal(compareValue('U*V', { algo: 'bcrypt', digest: '$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW' }), false);
    assert.throws(() => parseBcrypt('$2b$15$abcdefghijklmnopqrstuubyCG3zY1GIXMyxfivm.ClDiInHzxjiq'), HashError);
    assert.throws(() => parseBcrypt('$2x$05$abcdefghijklmnopqrstuubyCG3zY1GIXMyxfivm.ClDiInHzxjiq'), HashError);
});

test('argon2 d, i and id (versions 16 and 19) match argon2-cffi', () => {
    const cases = [
        ['password', '$argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQxMg$3gG+CxnCAlclnyOvhPPc2SFGZ3pXuizIWdXMZbJkba8'],
        ['correct horse', '$argon2i$v=19$m=128,t=3,p=4$c2FsdHNhbHRzYWx0MTYhIQ$hinudxgXBRbZXnyrGuJ2HjrOoInNckX0'],
        ['correct horse', '$argon2d$v=19$m=128,t=3,p=4$c2FsdHNhbHRzYWx0MTYhIQ$+8xENWxlFnGrWfdD+Kuep3XaDCBa7f3r'],
        ['correct horse', '$argon2id$v=19$m=128,t=3,p=4$c2FsdHNhbHRzYWx0MTYhIQ$hDnZfvZra3zYg2HTNgagBdffeq4yPA/Y'],
        ['pw', '$argon2id$v=16$m=32,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$lK4wGmDKBvKqXaDKKWQHue0VdOiIdQGMHltojJRYtL4'],
    ];
    for (const [pw, d] of cases) {
        assert.equal(compareValue(pw, { algo: 'argon2', digest: d }), true, d);
        assert.equal(compareValue(`${pw}!`, { algo: 'argon2', digest: d }), false, d);
    }
});

test('argon2 and bcrypt costs are capped; sha digests must be well formed', () => {
    assert.throws(() => parseArgon2('$argon2id$v=19$m=1048576,t=1,p=1$c29tZXNhbHQxMg$3gG+CxnCAlclnyOvhPPc2SFGZ3pXuizIWdXMZbJkba8'), /argon2 m/);
    assert.throws(() => parseArgon2('$argon2id$v=19$m=65536,t=10,p=1$c29tZXNhbHQxMg$3gG+CxnCAlclnyOvhPPc2SFGZ3pXuizIWdXMZbJkba8'), /m\*t/);
    assert.throws(() => parseArgon2('$argon2id$v=19$m=64,t=11,p=1$c29tZXNhbHQxMg$3gG+CxnCAlclnyOvhPPc2SFGZ3pXuizIWdXMZbJkba8'), /argon2 t/);
    assert.throws(() => compareValue('x', { algo: 'sha256', digest: 'abc' }), HashError);
    assert.throws(() => compareValue('x', { algo: 'md5', digest: 'abc' }), HashError);
    assert.throws(() => compareValue('x', { algo: 'bcrypt', digest: '$2b$04$abcdefghijklmnopqrstuubyCG3zY1GIXMyxfivm.ClDiInHzxjiq', salt: 's' }), /salt/);
    const h = createHash('sha256').update('pepperval').digest('hex');
    assert.equal(compareValue('val', { algo: 'sha256', digest: h, salt: 'pepper' }), true);
    assert.equal(compareValue('val', { algo: 'sha256', digest: h.toUpperCase(), salt: 'pepper' }), true);
    assert.equal(compareValue('val', { algo: 'sha256', digest: h }), false);
    assert.equal(compareValue('val', { algo: 'sha512', digest: createHash('sha512').update('val').digest('hex') }), true);
});

test('generated passwords: length, every class present, exclude honoured, never repeated', () => {
    const seen = new Set();
    for (let i = 0; i < 200; i++) {
        const p = generatePassword();
        assert.equal(p.length, 32);
        for (const c of Object.values(CLASSES)) assert.ok([...p].some((ch) => c.includes(ch)));
        seen.add(p);
    }
    assert.equal(seen.size, 200);
    const p = generatePassword({ length: 16, classes: ['lower', 'digits', 'symbols'], exclude: '!#$%&()*+,-./:;<=>?@[]^_{|}' });
    assert.equal(p.length, 16);
    assert.ok(/^[a-z0-9~]+$/.test(p) && p.includes('~'));
    assert.throws(() => checkSpec({ length: 15 }), /16\.\.128/);
    assert.throws(() => checkSpec({ length: 129 }), /16\.\.128/);
    assert.throws(() => checkSpec({ classes: ['emoji'] }), /classes/);
    assert.throws(() => checkSpec({ classes: ['digits'], exclude: '0123456789' }), /every character/);
    assert.throws(() => checkSpec({ value: 'hunter2' }), /unknown key/);
    assert.throws(() => checkSpec('hunter2'), /object/);
});
