// node:test suite for the window warden in kiosk/happy-kiosk.mjs. It runs in the browser-node
// beside the image's playwright; here "playwright" resolves to a stub and the launch hook is
// off (HAPPY_KIOSK_NO_AUTOLOAD=1), so only the exported helpers and watch() are tested, over a
// fake CDP session.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { register } from 'node:module';

const STUB = 'data:text/javascript,export const chromium = {};';
register(`data:text/javascript,${encodeURIComponent(`export async function resolve(s, c, next) { return s === 'playwright' ? { url: ${JSON.stringify(STUB)}, shortCircuit: true } : next(s, c); }`)}`);
process.env.HAPPY_KIOSK_NO_AUTOLOAD = '1';
const K = await import('../happy-kiosk.mjs');

test('BROWSER_KIOSK picks the flags: 1 the kiosk, anything else a maximized window', () => {
    assert.equal(K.kioskMode({}), false);
    assert.equal(K.kioskMode({ BROWSER_KIOSK: '0' }), false);
    assert.equal(K.kioskMode({ BROWSER_KIOSK: '1' }), true);
    assert.equal(K.argsFor(false), K.WINDOW_ARGS);
    assert.equal(K.argsFor(true), K.KIOSK_ARGS);
    assert.ok(K.WINDOW_ARGS.includes('--start-maximized') && !K.WINDOW_ARGS.includes('--kiosk'));
    assert.ok(K.KIOSK_ARGS.includes('--kiosk') && !K.KIOSK_ARGS.includes('--start-maximized'));
    for (const a of K.WINDOW_ARGS) assert.ok(!/fullscreen|app=/.test(a), a);
    assert.equal(K.wantedState(false), 'maximized');
    assert.equal(K.wantedState(true), 'fullscreen');
});

test('stepsTo: maximized only from normal, so fullscreen and minimized are restored first', () => {
    assert.deepEqual(K.stepsTo('maximized', 'maximized'), []);
    assert.deepEqual(K.stepsTo('fullscreen', 'maximized'), ['normal', 'maximized']);
    assert.deepEqual(K.stepsTo('minimized', 'maximized'), ['normal', 'maximized']);
    assert.deepEqual(K.stepsTo('normal', 'maximized'), ['maximized']);
    assert.deepEqual(K.stepsTo('normal', 'fullscreen'), ['fullscreen']);
    assert.deepEqual(K.stepsTo('maximized', 'fullscreen'), ['fullscreen']);
    assert.deepEqual(K.stepsTo('fullscreen', 'fullscreen'), []);
});

// A browser's CDP: page targets with windows, every setWindowBounds applied and recorded.
function fakeCdp(windows) {
    const handlers = {};
    const set = [];
    const urls = {};
    const sent = [];
    const detached = [];
    return {
        set, windows, urls, sent, detached,
        on(ev, fn) { handlers[ev] = fn; },
        emit(ev, p) { handlers[ev]?.(p); },
        async send(method, p = {}) {
            if (method === 'Target.setDiscoverTargets') return {};
            if (method === 'Target.getTargets') return { targetInfos: [...Object.keys(windows).map((targetId) => ({ targetId, type: 'page', url: urls[targetId] || 'about:blank' })), { targetId: 'sw', type: 'service_worker', url: 'view-source:x' }] };
            if (method === 'Target.attachToTarget') { assert.equal(p.flatten, false); return { sessionId: `S-${p.targetId}` }; }
            if (method === 'Target.sendMessageToTarget') { sent.push([p.sessionId, JSON.parse(p.message)]); return {}; }
            if (method === 'Target.detachFromTarget') { detached.push(p.sessionId); return {}; }
            if (method === 'Browser.getWindowForTarget') {
                if (!windows[p.targetId]) throw new Error('No target with given id found');
                return { windowId: p.targetId, bounds: { windowState: windows[p.targetId] } };
            }
            if (method === 'Browser.setWindowBounds') { set.push([p.windowId, p.bounds.windowState]); windows[p.windowId] = p.bounds.windowState; return {}; }
            throw new Error(`unexpected ${method}`);
        },
    };
}
const quiet = { log() {}, warn() {} };
const tick = () => new Promise((r) => setTimeout(r, 10));

test('watch holds every page window maximized by default, popups too', async () => {
    const cdp = fakeCdp({ a: 'fullscreen', b: 'normal', c: 'maximized' });
    const lines = [];
    const w = await K.watch(cdp, { log: { log: (l) => lines.push(l), warn() {} }, intervalMs: 60_000 });
    assert.deepEqual(cdp.windows, { a: 'maximized', b: 'maximized', c: 'maximized' });
    assert.deepEqual(cdp.set.filter(([id]) => id === 'a'), [['a', 'normal'], ['a', 'maximized']]);
    assert.deepEqual(cdp.set.filter(([id]) => id === 'b'), [['b', 'maximized']]);
    assert.ok(!cdp.set.some(([id]) => id === 'c' || id === 'sw'));
    assert.match(lines.join('\n'), /maximized, with its tab strip and address bar/);
    // A popup opened later, and a window someone minimized.
    cdp.windows.p = 'normal';
    cdp.emit('Target.targetCreated', { targetInfo: { targetId: 'p', type: 'page' } });
    cdp.emit('Target.targetCreated', { targetInfo: { targetId: 'sw2', type: 'service_worker' } });
    await tick();
    assert.equal(cdp.windows.p, 'maximized');
    cdp.windows.a = 'minimized';
    cdp.set.length = 0;
    await w.sweep();
    assert.deepEqual(cdp.set, [['a', 'normal'], ['a', 'maximized']]);
    w.stop();
});

test('watch with kiosk holds fullscreen; a window gone in between is not an error', async () => {
    const cdp = fakeCdp({ a: 'maximized', b: 'normal' });
    const warns = [];
    const w = await K.watch(cdp, { log: { log() {}, warn: (l) => warns.push(l) }, intervalMs: 60_000, kiosk: true });
    assert.deepEqual(cdp.windows, { a: 'fullscreen', b: 'fullscreen' });
    cdp.emit('Target.targetCreated', { targetInfo: { targetId: 'gone', type: 'page' } });
    await tick();
    assert.deepEqual(warns, []);
    let stopped = false;
    const w2 = await K.watch(fakeCdp({}), { log: quiet, intervalMs: 60_000, onStop: () => { stopped = true; } });
    w2.stop();
    assert.equal(stopped, true);
    w.stop();
});

test('forbiddenUrl: view-source in any case, nothing else', () => {
    for (const u of ['view-source:file:///etc/passwd', 'VIEW-SOURCE:https://x', ' view-source:about:blank']) assert.equal(K.forbiddenUrl(u), true, u);
    for (const u of ['https://example.com/view-source:x', 'about:blank', 'chrome-error://chromewebdata/', '', undefined]) assert.equal(K.forbiddenUrl(u), false, String(u));
});

test('watch sends a page that commits view-source: to about:blank, on commit and on the sweep', async () => {
    const cdp = fakeCdp({ a: 'maximized', b: 'maximized' });
    cdp.urls.b = 'view-source:file:///etc/passwd';
    const warns = [];
    const w = await K.watch(cdp, { log: { log() {}, warn: (l) => warns.push(l) }, intervalMs: 60_000 });
    await tick();
    assert.deepEqual(cdp.sent, [['S-b', { id: 1, method: 'Page.navigate', params: { url: 'about:blank' } }]]);
    assert.deepEqual(cdp.detached, ['S-b']);
    assert.match(warns.join('\n'), /sent a view-source: page to about:blank/);
    // A tab someone types it into later; an ordinary page and a non-page target are left alone.
    cdp.sent.length = 0;
    cdp.emit('Target.targetInfoChanged', { targetInfo: { targetId: 'a', type: 'page', url: 'view-source:about:blank' } });
    cdp.emit('Target.targetInfoChanged', { targetInfo: { targetId: 'b', type: 'page', url: 'https://example.com/' } });
    cdp.emit('Target.targetInfoChanged', { targetInfo: { targetId: 'sw', type: 'service_worker', url: 'view-source:x' } });
    await tick();
    assert.deepEqual(cdp.sent.map(([sid]) => sid), ['S-a']);
    w.stop();
});
