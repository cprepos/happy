import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildEquivalence, describeEquivalents, equivalentsFor, registrableDomain } from '../lib/providers/vaultwarden/domains.mjs';
import { matchAllowed } from '../lib/hosts.mjs';

test('registrable domains follow the public suffix list', () => {
    for (const [h, want] of [
        ['accounts.google.com', 'google.com'], ['google.com', 'google.com'], ['www.gmail.com.', 'gmail.com'],
        ['www.foo.co.uk', 'foo.co.uk'], ['bar.co.uk', 'bar.co.uk'], ['a.b.foo.com.au', 'foo.com.au'],
        ['shop.amazon.co.jp', 'amazon.co.jp'], ['evil.net.cn', 'evil.net.cn'],
        ['me.github.io', 'me.github.io'], ['x.y.myshopify.com', 'y.myshopify.com'], ['www.site.ck', 'www.site.ck'],
        ['co.uk', null], ['uk', null], ['github.io', null], ['net.cn', null], ['1.2.3.4', null], ['localhost', null], ['', null], [null, null],
    ]) assert.equal(registrableDomain(h), want, String(h));
    assert.notEqual(registrableDomain('foo.co.uk'), registrableDomain('bar.co.uk'));
});

test('equivalence groups: custom and non-excluded global groups, never a public suffix', () => {
    const idx = buildEquivalence({
        equivalentDomains: [['foo.co.uk', 'foo-shop.com'], ['solo.test'], ['co.uk', 'lonely.test']],
        globalEquivalentDomains: [
            { type: 0, domains: ['youtube.com', 'google.com', 'gmail.com'], excluded: false },
            { type: 1, domains: ['apple.com', 'icloud.com'], excluded: true },
            { type: 41, domains: ['shop-cn.test', 'net.cn', 'www.sub.test'], excluded: false },
            { type: 63, domains: ['shopify.com', 'myshopify.com'], excluded: false },
            { type: 99, domains: ['gmail.com', 'googlemail.com'], excluded: false },
        ],
    });
    assert.deepEqual([...idx.get('gmail.com')].sort(), ['gmail.com', 'google.com', 'googlemail.com', 'youtube.com'], 'overlapping groups are united');
    assert.deepEqual([...idx.get('google.com')].sort(), ['gmail.com', 'google.com', 'youtube.com']);
    assert.deepEqual([...idx.get('foo.co.uk')].sort(), ['foo-shop.com', 'foo.co.uk']);
    for (const gone of ['apple.com', 'icloud.com', 'net.cn', 'co.uk', 'myshopify.com', 'shopify.com', 'shop-cn.test', 'solo.test', 'lonely.test', 'www.sub.test']) assert.ok(!idx.has(gone), gone);
    assert.equal(buildEquivalence(null).size, 0);
    assert.equal(buildEquivalence({ globalEquivalentDomains: 'junk', equivalentDomains: [null, 5] }).size, 0);
});

test('matching: exact hosts, or a registrable domain an equivalence grants, on https only', () => {
    const idx = buildEquivalence({ equivalentDomains: [['foo.co.uk', 'foo-shop.com']], globalEquivalentDomains: [{ domains: ['youtube.com', 'google.com', 'gmail.com'] }] });
    const equiv = equivalentsFor(['www.gmail.com', 'www.foo.co.uk', 'portal.acme.test'], idx);
    assert.deepEqual(Object.fromEntries(equiv), { 'gmail.com': 'www.gmail.com', 'google.com': 'www.gmail.com', 'youtube.com': 'www.gmail.com', 'foo-shop.com': 'www.foo.co.uk', 'foo.co.uk': 'www.foo.co.uk' });
    const allow = { hosts: ['www.gmail.com', 'www.foo.co.uk', 'portal.acme.test'], equiv };
    assert.deepEqual(matchAllowed('https://www.gmail.com/x', allow), { host: 'www.gmail.com' });
    assert.deepEqual(matchAllowed('https://accounts.google.com/signin?x=1', allow), { host: 'accounts.google.com', equivalent_of: 'www.gmail.com' });
    assert.deepEqual(matchAllowed('https://mail.gmail.com/', allow), { host: 'mail.gmail.com', equivalent_of: 'www.gmail.com' });
    assert.deepEqual(matchAllowed('https://shop.foo-shop.com/', allow), { host: 'shop.foo-shop.com', equivalent_of: 'www.foo.co.uk' });
    for (const bad of ['http://accounts.google.com/', 'https://bar.co.uk/', 'https://foo.co.uk.evil.test/', 'https://google.com.evil.test/',
        'https://evilgoogle.com/', 'https://x.acme.test/', 'https://accounts.google.com:8443/', 'https://u:p@accounts.google.com/', 'https://1.2.3.4/']) {
        assert.equal(matchAllowed(bad, allow), null, bad);
    }
    assert.equal(matchAllowed('https://accounts.google.com/', { hosts: ['www.gmail.com'], equiv: null }), null, 'no equiv map: exact only');
});

test('the equivalents label is short', () => {
    const idx = buildEquivalence({ globalEquivalentDomains: [{ domains: ['youtube.com', 'google.com', 'gmail.com'] }, { domains: ['amazon.com', 'amazon.ca', 'amazon.cn', 'amazon.co.jp', 'amazon.de', 'amazon.fr'] }] });
    assert.equal(describeEquivalents(['www.gmail.com'], equivalentsFor(['www.gmail.com'], idx)), '+ google.com, youtube.com equivalents');
    assert.equal(describeEquivalents(['www.amazon.com'], equivalentsFor(['www.amazon.com'], idx)), '+ amazon.ca, amazon.cn, amazon.co.jp … 2 more equivalents');
    assert.equal(describeEquivalents(['github.com'], equivalentsFor(['github.com'], idx)), null);
});
