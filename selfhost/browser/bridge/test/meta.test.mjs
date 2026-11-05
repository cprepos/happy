// The BRIDGE_LOG_META probe logs keys and hashes, never a raw value.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMetaProbe, createMcpServer } from '../mcp.mjs';

test('meta probe is off unless BRIDGE_LOG_META is set', () => {
    assert.equal(createMetaProbe({}), null);
    assert.equal(createMetaProbe({ BRIDGE_LOG_META: '0' }), null);
});

test('meta probe logs keys and hashes only', async () => {
    const lines = [];
    const secretish = 'chat-0123456789abcdef-raw';
    const probe = createMetaProbe({ BRIDGE_LOG_META: '1', CLAUDE_CODE_SESSION_ID: secretish, HAPPY_SERVER_URL: 'http://x', PATH: '/bin' }, (l) => lines.push(l));
    const server = createMcpServer({ bridgeUrl: 'http://127.0.0.1:1', bridgeToken: 't', write: () => {}, metaProbe: probe });
    await server.handle({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { clientInfo: { name: 'claude-code', version: '9' }, capabilities: { roots: {} } } });
    await server.handle({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'nope', arguments: {}, _meta: { 'claudecode/toolUseId': secretish, progressToken: 3 } } });
    const all = lines.join('\n');
    assert.ok(!all.includes(secretish));
    const start = JSON.parse(lines[0]);
    assert.deepEqual(Object.keys(start.env), ['CLAUDE_CODE_SESSION_ID']);
    assert.match(start.env.CLAUDE_CODE_SESSION_ID, /^[0-9a-f]{12}$/);
    assert.equal(JSON.parse(lines[1]).client, 'claude-code');
    assert.deepEqual(JSON.parse(lines[2]).metaKeys, ['claudecode/toolUseId', 'progressToken']);
});
