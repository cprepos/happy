// The live page's script run against a fake DOM and fetch, on mocked timers: when its spinner
// shows over the last frame. A slow read that answers, or the same picture again, never spins it;
// frame reads that fail or never answer for FRAME_WAIT_SPIN_MS do.
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { renderPage, FRAME_WAIT_SPIN_MS, FRAME_READ_TIMEOUT_MS } from '../lib/page.mjs';

const ID = 'a'.repeat(32);
const SCRIPT = renderPage({ id: ID, state: { status: 'watching', url: 'https://example.com/', title: 'Example' }, takeoverUrl: '', nonce: 'n' })
    .match(/<script nonce="n">([\s\S]*?)<\/script>/)[1];

function el(id) {
    const classes = new Set();
    return {
        id, hidden: false, textContent: '', className: '', disabled: false, href: '', src: '',
        classList: { toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)), contains: (c) => classes.has(c) },
        style: { setProperty() {} },
        addEventListener() {}, appendChild() {},
        attrs: {}, setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return this.attrs[k] ?? null; },
    };
}

// answer(path, signal): a Promise of {status, body}, or one that never settles.
function load(answer) {
    const els = new Map();
    const $ = (id) => {
        if (!els.has(id)) {
            const e = el(id);
            if (id === 'initial') e.textContent = JSON.stringify({ status: 'watching' });
            if (id === 'spin') e.hidden = true;
            els.set(id, e);
        }
        return els.get(id);
    };
    const asks = [];
    const fetch = (url, opts = {}) => {
        const path = url.slice(`/live/${ID}`.length);
        asks.push(path);
        return new Promise((resolve, reject) => {
            opts.signal?.addEventListener('abort', () => reject(new Error('aborted')));
            answer(path).then((a) => resolve({
                status: a.status, ok: a.status >= 200 && a.status < 300,
                json: async () => a.body, blob: async () => a.body,
            }), reject);
        });
    };
    class Image { constructor() { this.naturalWidth = 1920; this.naturalHeight = 1200; } async decode() {} }
    const context = vm.createContext({
        document: { getElementById: $, hidden: false, addEventListener() {}, createElement: () => el('li'), title: '' },
        location: { pathname: `/live/${ID}`, href: `http://localhost/live/${ID}`, origin: 'http://localhost' },
        URL: { createObjectURL: () => 'blob:x', revokeObjectURL() {} },
        URLSearchParams, Image, fetch, AbortController, JSON, Math, Date, Promise, Array, String, Object,
        setTimeout, clearTimeout,
    });
    vm.runInContext(SCRIPT, context);
    return { spinning: () => !$('spin').hidden, asks, $ };
}

const flush = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };
// Moves the mocked clock on in small steps, so timers set along the way fire in order.
async function advance(ms, step = 50) {
    for (let t = 0; t < ms; t += step) { mock.timers.tick(step); await flush(); }
}
const later = (ms, value) => new Promise((r) => setTimeout(() => r(value), ms));

test('the same picture again, each read slower than the spinner limit was from the last frame: never spins', async (t) => {
    mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1_000_000 });
    t.after(() => mock.timers.reset());
    const slow = FRAME_WAIT_SPIN_MS - 200; // under the limit by itself, over it counted from the last frame (plus the gap)
    const page = load((path) => (path === '/state' ? Promise.resolve({ status: 200, body: { status: 'watching' } }) : later(slow, { status: 200, body: 'same' })));
    await flush();
    assert.ok(page.spinning(), 'no frame yet: spins');
    await advance(slow + 100);
    assert.ok(!page.spinning(), 'a frame: no spinner');
    let spun = false;
    for (let i = 0; i < 60; i++) { await advance(250); spun ||= page.spinning(); }
    assert.ok(!spun, 'slow answers of an unchanged picture never spin');
    assert.ok(page.asks.filter((p) => p === '/frame.jpg').length >= 4);
});

test('frame reads failing for FRAME_WAIT_SPIN_MS spin over the last frame; a frame stops it', async (t) => {
    mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1_000_000 });
    t.after(() => mock.timers.reset());
    let failing = false;
    const page = load((path) => (path === '/state' ? Promise.resolve({ status: 200, body: { status: 'watching' } })
        : Promise.resolve(failing ? { status: 502, body: null } : { status: 200, body: 'f' })));
    await advance(400);
    assert.ok(!page.spinning());
    failing = true;
    await advance(FRAME_WAIT_SPIN_MS - 800);
    assert.ok(!page.spinning(), 'a moment of failures: the frame stays up alone');
    await advance(1500);
    assert.ok(page.spinning(), 'failing for the limit: spins');
    failing = false;
    await advance(2000);
    assert.ok(!page.spinning(), 'a frame again: stops');
});

test('a frame read that never answers is given up on and spins; the loop goes on', async (t) => {
    mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1_000_000 });
    t.after(() => mock.timers.reset());
    let hang = false;
    const page = load((path) => (path === '/state' ? Promise.resolve({ status: 200, body: { status: 'watching' } })
        : hang ? new Promise(() => {}) : Promise.resolve({ status: 200, body: 'f' })));
    await advance(400);
    hang = true;
    await advance(FRAME_WAIT_SPIN_MS + 500);
    assert.ok(page.spinning(), 'no answer for the limit: spins');
    const asked = page.asks.length;
    hang = false;
    await advance(FRAME_READ_TIMEOUT_MS + 2000);
    assert.ok(page.asks.length > asked, 'the hung read was given up on and asked again');
    assert.ok(!page.spinning(), 'and the next frame stops the spinner');
});
