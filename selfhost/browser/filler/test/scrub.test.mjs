import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createScrubber, variantsOf } from '../lib/scrub.mjs';

const SECRET = 'Acme+Pass/w0rd=1&x "q" <t> \'a\' é';

function encodings(v) {
    const b = Buffer.from(v, 'utf8');
    const out = {
        plain: v,
        uri: encodeURIComponent(v),
        form: new URLSearchParams({ p: v }).toString().slice(2),
        json: JSON.stringify(v),
        json2: JSON.stringify(JSON.stringify(v)),
        jsonAscii: JSON.stringify(v).replace(/[\u0080-￿]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')),
        html: v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;'),
    };
    for (const prefix of ['', 'u', 'us', 'user:']) {
        const enc = Buffer.concat([Buffer.from(prefix), b, Buffer.from('tail')]).toString('base64');
        out[`b64_${prefix.length}`] = enc;
        out[`b64url_${prefix.length}`] = enc.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }
    out.basic = 'Basic ' + Buffer.from(`bot:${v}`).toString('base64');
    return out;
}

test('every encoding and base64 alignment is scrubbed', () => {
    const s = createScrubber();
    s.add('sess1', 'acme.github.password', SECRET);
    for (const [kind, text] of Object.entries(encodings(SECRET))) {
        const out = s.scrubString(`before ${text} after`);
        assert.ok(!s.leaks(out), `${kind} still leaks: ${out.slice(0, 40)}`);
        assert.match(out, /\[secret:acme\.github\.password\]/, kind);
    }
});

test('nested values, keys and errors are scrubbed; images dropped on request', () => {
    const s = createScrubber();
    s.add('sess1', 'acme.github.username', 'acme-bot@example.com');
    const payload = {
        content: [{ type: 'text', text: 'Signed in as acme-bot@example.com' }, { type: 'image', data: 'AAAA', mimeType: 'image/png' }],
        structuredContent: { deep: [[{ 'acme-bot@example.com': { v: 'acme-bot%40example.com' } }]] },
        error: { message: 'value "acme-bot@example.com" rejected' },
    };
    const out = s.scrub(payload, { dropImages: true });
    const text = JSON.stringify(out);
    assert.ok(!text.includes('acme-bot'), text);
    assert.equal(out.content[1].type, 'text');
    assert.match(out.content[1].text, /withheld/);
    assert.equal(s.scrub(payload).content[1].type, 'image');
    assert.equal(s.scrub(new Error('x acme-bot@example.com')).message, 'x [secret:acme.github.username]');
});

test('drop forgets a session, and longest variants win', () => {
    const s = createScrubber();
    s.add('a', 'n.short', 'abc123');
    s.add('b', 'n.long', 'abc123xyz');
    assert.equal(s.scrubString('abc123xyz abc123'), '[secret:n.long] [secret:n.short]');
    s.drop('b');
    assert.equal(s.scrubString('abc123xyz'), '[secret:n.short]xyz');
    assert.ok(variantsOf('p@ss w').includes('p%40ss+w'));
});
