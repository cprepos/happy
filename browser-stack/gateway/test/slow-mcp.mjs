#!/usr/bin/env node
// A tiny stdio MCP server for checking the LAN gateway path end to end (route /gwtest, only
// with gateway-config.py --routes ...,test). It touches nothing: no browser, no vault.
//   whoami          the chat this call's _meta names (chatmeta.mjs), and the _meta keys seen
//   wait {seconds}  holds the call open, sending a progress notification every 5 s when the
//                   call has a progressToken; stops early on notifications/cancelled
import { createInterface } from 'node:readline';
import { chatFromMeta, chatOfMeta } from '../../identity/chatmeta.mjs';

const out = (m) => process.stdout.write(JSON.stringify(m) + '\n');
const timers = new Map(); // request id -> {timer, finish}
const TOOLS = [
    { name: 'whoami', description: 'The chat this call came from.', inputSchema: { type: 'object', properties: {} } },
    { name: 'wait', description: 'Wait, with progress.', inputSchema: { type: 'object', properties: { seconds: { type: 'number' } } } },
];
const text = (s) => ({ content: [{ type: 'text', text: s }] });

createInterface({ input: process.stdin }).on('line', (line) => {
    let m;
    try { m = JSON.parse(line); } catch { return; }
    if (m.method === 'initialize') {
        return out({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: m.params?.protocolVersion ?? '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'gateway-test', version: '0.0.1' } } });
    }
    if (m.method === 'notifications/cancelled') {
        const t = timers.get(m.params?.requestId);
        if (t) t.finish('cancelled');
        return;
    }
    if (m.method === 'ping') return out({ jsonrpc: '2.0', id: m.id, result: {} });
    if (m.method === 'tools/list') return out({ jsonrpc: '2.0', id: m.id, result: { tools: TOOLS } });
    if (m.method !== 'tools/call') {
        if (m.id !== undefined) out({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'method not found' } });
        return;
    }
    const meta = m.params?._meta;
    if (m.params?.name === 'whoami') {
        const chat = chatFromMeta() ? chatOfMeta(meta) : null;
        return out({ jsonrpc: '2.0', id: m.id, result: text(JSON.stringify({ chat, metaKeys: meta && typeof meta === 'object' ? Object.keys(meta).sort() : [] })) });
    }
    if (m.params?.name === 'wait') {
        const total = Math.max(0, Math.min(900, Number(m.params?.arguments?.seconds) || 0));
        const token = meta?.progressToken;
        const started = Date.now();
        let n = 0;
        const tick = setInterval(() => {
            if (token !== undefined) out({ jsonrpc: '2.0', method: 'notifications/progress', params: { progressToken: token, progress: ++n, message: `waited ${Math.round((Date.now() - started) / 1000)} s` } });
        }, 5000);
        const finish = (how) => {
            clearInterval(tick); clearTimeout(done); timers.delete(m.id);
            if (how !== 'cancelled') out({ jsonrpc: '2.0', id: m.id, result: text(`waited ${Math.round((Date.now() - started) / 1000)} s`) });
        };
        const done = setTimeout(() => finish('done'), total * 1000);
        timers.set(m.id, { finish });
        return;
    }
    out({ jsonrpc: '2.0', id: m.id, result: { ...text(`unknown tool ${m.params?.name}`), isError: true } });
});
