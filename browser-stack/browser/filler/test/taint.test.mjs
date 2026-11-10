import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createScrubber } from '../lib/scrub.mjs';
import { createTaint } from '../lib/taint.mjs';

test('images are withheld only for the chat that typed a username or TOTP; no chat id fails closed', () => {
    const taint = createTaint({ scrubber: createScrubber() });
    assert.equal(taint.dropImagesForChat('chat-a'), false);
    taint.mark('8100/s1', { chat: 'chat-a', client: 'acme', name: 'github.password', value: 'pw-0123456789', kind: 'password' });
    assert.equal(taint.dropImagesForChat('chat-a'), false, 'a password alone keeps images');
    assert.equal(taint.dropImagesForChat(''), false);
    taint.mark('8100/s1', { chat: 'chat-a', client: 'acme', name: 'github.username', value: 'bot@example.com', kind: 'username' });
    assert.equal(taint.dropImagesForChat('chat-a'), true);
    assert.equal(taint.dropImagesForChat('chat-b'), false);
    for (const none of ['', null, undefined, 'none']) assert.equal(taint.dropImagesForChat(none), true);
    assert.equal(taint.anyDropImages(), true);
});
