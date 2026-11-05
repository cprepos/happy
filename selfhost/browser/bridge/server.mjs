#!/usr/bin/env node
// happy-browser-bridge HTTP service, bound to 127.0.0.1:6090.
import { createServer } from 'node:http';
import { createAutoBrowserClient } from './lib/autobrowser.mjs';
import { createBridge } from './lib/app.mjs';
import { loadConfig, readSecret } from './lib/config.mjs';
import { createLauncherClient, createPodClient, createPodManager } from './lib/pods.mjs';
import { LinkStore } from './lib/store.mjs';

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
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 3000).unref();
    });
}
