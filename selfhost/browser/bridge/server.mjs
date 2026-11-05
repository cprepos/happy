#!/usr/bin/env node
// happy-browser-bridge HTTP service, bound to 127.0.0.1:6090.
import { readFileSync, renameSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { createAutoBrowserClient } from './lib/autobrowser.mjs';
import { createBridge } from './lib/app.mjs';
import { loadConfig, readSecret } from './lib/config.mjs';
import { createLauncherClient, createPodClient, createPodManager } from './lib/pods.mjs';
import { LinkStore } from './lib/store.mjs';
import { createUpstreamMcp } from './lib/upstream.mjs';

const cfg = loadConfig();
const log = (msg) => console.log(`${new Date().toISOString()} ${msg}`);

const store = new LinkStore({ path: cfg.storePath, idleMs: cfg.idleMs });
// One pod per chat, when enabled: lib/pods.mjs, through the launcher's unix socket.
const pods = cfg.pods.enabled ? createPodManager({
    launcher: createLauncherClient(cfg.pods.launcherSocket),
    clientFor: ({ apiPort }) => createPodClient({ baseUrl: `http://127.0.0.1:${apiPort}`, token: readSecret(cfg.files.apiToken) }),
    store,
    maxPods: cfg.pods.maxPods,
    warm: cfg.pods.warm,
    idleMs: cfg.pods.idleMs,
    portBases: cfg.pods.bases,
    podsPath: cfg.pods.podsPath,
    chatsPath: cfg.pods.chatsPath,
    log,
}) : null;
// auto-browser's tool list for /api/tools: every pod runs the same image, so one list serves all.
// Kept in memory and on disk; filled from a pod that is up (a spare or a chat's), else from the
// shared controller. Listing tools never starts a pod.
function createToolLister() {
    const path = join(dirname(cfg.pods.podsPath), 'tools.json');
    let cached = null;
    try { cached = JSON.parse(readFileSync(path, 'utf8')).tools ?? null; } catch {}
    let fetchedAt = 0;
    let inflight = null;
    async function fetchFrom(url) {
        const up = createUpstreamMcp({ url, getToken: () => readSecret(cfg.files.apiToken), timeoutMs: 15_000 });
        return up.listTools();
    }
    async function refresh() {
        const urls = pods.status().pods.filter((p) => (p.state === 'ready' || p.state === 'assigned') && p.ports?.api).map((p) => `http://127.0.0.1:${p.ports.api}/mcp`);
        urls.push(cfg.autoBrowserMcpUrl);
        let last = null;
        for (const url of urls) {
            try {
                const tools = await fetchFrom(url);
                if (!tools.length) continue;
                cached = tools;
                fetchedAt = Date.now();
                try {
                    writeFileSync(`${path}.tmp`, JSON.stringify({ fetched_at: new Date().toISOString(), tools }), { mode: 0o600 });
                    renameSync(`${path}.tmp`, path);
                } catch (err) { log(`tools: saving the list failed: ${err.message}`); }
                return tools;
            } catch (err) { last = err; }
        }
        throw Object.assign(new Error(`no browser is up to list tools from${last ? ` (${last.message})` : ''}`), { status: 503 });
    }
    return async () => {
        // Once per bridge run (the image may have changed), in the background when a list is cached.
        if (!fetchedAt && !inflight) inflight = refresh().finally(() => { inflight = null; });
        if (cached) { inflight?.catch(() => {}); return cached; }
        return inflight ?? refresh();
    };
}

const client = createAutoBrowserClient({ baseUrl: cfg.autoBrowserUrl, token: readSecret(cfg.files.apiToken) });
const bridge = createBridge({
    client,
    store,
    log,
    config: {
        publicBase: cfg.publicBase,
        novncUrl: cfg.novncUrl,
        vncPassword: readSecret(cfg.files.vncPassword),
        bridgeToken: readSecret(cfg.files.bridgeToken),
        frameWidth: cfg.frameWidth,
        frameHeight: cfg.frameHeight,
        pods,
        listTools: pods ? createToolLister() : null,
        // The user ended the browser: its pod goes through the normal stop (save the login,
        // stash it, close, stop). The idle timer stays as it is.
        onEnd: pods ? async ({ id }) => {
            const chat = pods.chatForLink(id);
            if (chat) await pods.stopChat(chat.chatKey, 'user_ended');
        } : null,
        // The phone opens http://localhost:<port>; the MCP server and probes use 127.0.0.1.
        allowedHosts: [`localhost:${cfg.port}`, `127.0.0.1:${cfg.port}`, `[::1]:${cfg.port}`],
    },
});

const server = createServer(bridge.handler);
// noVNC's websocket for /live/<id>/vnc/websockify; every other upgrade is refused.
server.on('upgrade', bridge.upgrade);
// /api/wait long-polls for up to two minutes.
server.requestTimeout = 0;
server.headersTimeout = 15_000;
server.keepAliveTimeout = 5_000;
server.listen(cfg.port, cfg.host, () => log(`bridge listening on http://${cfg.host}:${cfg.port} -> ${pods ? `browser pods (max ${cfg.pods.maxPods}, warm ${cfg.pods.warm})` : cfg.autoBrowserUrl}`));
pods?.start().catch((err) => log(`pods: start failed: ${err.message}`));

const sweep = setInterval(() => store.sweep(), 60_000);
sweep.unref();
for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => {
        log(`${sig}: shutting down`);
        store.flush();
        pods?.close();
        bridge.close();
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 3000).unref();
    });
}
