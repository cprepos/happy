// node:test checks on the fluxbox configs in kiosk/fluxbox: the window mode's desktop panel (the
// evidence screenshots' clock) and the kiosk's lack of one. Plain file reads, no X.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'fluxbox');
const resources = (name) => Object.fromEntries(
    readFileSync(join(DIR, name), 'utf8').split('\n').filter((l) => l.trim() && !l.startsWith('!'))
        .map((l) => { const i = l.indexOf(':'); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }),
);

test('window mode: a panel across the top that a maximized window stays below', () => {
    const r = resources('init.window');
    assert.equal(r['session.screen0.toolbar.visible'], 'true');
    assert.equal(r['session.screen0.toolbar.placement'], 'TopCenter');
    assert.equal(r['session.screen0.toolbar.widthPercent'], '100');
    assert.equal(r['session.screen0.toolbar.autoHide'], 'false');
    // maxOver false: the panel reserves its strip (_NET_WORKAREA), so Chromium never covers it.
    assert.equal(r['session.screen0.toolbar.maxOver'], 'false');
    // browser.mk reads this for BROWSER_PANEL_HEIGHT; the live height is measured from _NET_WORKAREA.
    assert.match(r['session.screen0.toolbar.height'], /^[1-9][0-9]*$/);
    assert.equal(r['session.screen0.toolbar.tools'], 'iconbar, clock');
    // The clock shows the date with its year, and seconds.
    for (const f of ['%Y', '%d', '%b', '%H', '%M', '%S']) assert.ok(r['session.screen0.strftimeFormat'].includes(f), f);
    // Still no way to drive fluxbox from a client, no bindings, no menu.
    assert.equal(r['session.screen0.allowRemoteActions'], 'false');
    assert.equal(r['session.screen0.workspaces'], '1');
    assert.equal(r['session.keyFile'], '/happy/fluxbox/keys');
    assert.equal(r['session.menuFile'], '/happy/fluxbox/menu');
    assert.equal(r['session.styleFile'], '/happy/fluxbox/style');
});

test('the panel style: a flat grey bar with DejaVu Sans text', () => {
    const s = resources('style');
    assert.equal(s['toolbar.color'], '#2b2b2b');
    for (const k of ['toolbar.clock.font', 'toolbar.iconbar.focused.font', 'toolbar.iconbar.unfocused.font']) {
        assert.match(s[k], /^DejaVu Sans-\d+$/, k);
    }
    assert.equal(s['background.color'], '#1e1e1e');
});

test('the kiosk has no panel', () => {
    const r = resources('init');
    assert.equal(r['session.screen0.toolbar.visible'], 'false');
    assert.equal(r['session.screen0.allowRemoteActions'], 'false');
});
