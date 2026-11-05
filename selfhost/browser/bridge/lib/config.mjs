// Settings shared by the HTTP service and the MCP server. Secrets are read
// from files (paths below), never from argv or the environment's values.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export function loadConfig(env = process.env) {
    const home = env.HAPPY_BROWSER_HOME || join(homedir(), '.local/share/happy-browser');
    const secrets = env.HAPPY_BROWSER_SECRETS || join(home, 'secrets');
    const port = Number(env.BRIDGE_PORT || 6090);
    return {
        home,
        host: env.BRIDGE_HOST || '127.0.0.1',
        port,
        publicBase: env.BRIDGE_PUBLIC_BASE || `http://localhost:${port}`,
        bridgeUrl: env.BRIDGE_URL || `http://127.0.0.1:${port}`,
        autoBrowserUrl: env.AUTO_BROWSER_URL || 'http://127.0.0.1:8010',
        autoBrowserMcpUrl: env.AUTO_BROWSER_MCP_URL || `${(env.AUTO_BROWSER_URL || 'http://127.0.0.1:8010').replace(/\/+$/, '')}/mcp`,
        // The controller's port, which the secret filler is told so it types into the same browser.
        autoBrowserPort: Number(new URL(env.AUTO_BROWSER_URL || 'http://127.0.0.1:8010').port || 80),
        // The secret filler (selfhost/browser/filler); off unless files.fillerToken exists.
        fillerUrl: env.FILLER_URL || 'http://127.0.0.1:6091',
        // Per-call limit for a forwarded auto-browser tool call.
        passthroughTimeoutS: Number(env.BRIDGE_PASSTHROUGH_TIMEOUT_S || 120),
        // Upper bound for browser_wait_for_human's timeout_s. Keep it below the
        // client's tool timeout (Happy Agent allows at most 600 s).
        waitMaxS: Math.max(5, Math.min(3600, Number(env.BRIDGE_WAIT_MAX_S || 3600))),
        novncUrl: env.NOVNC_URL || 'http://localhost:6080/vnc.html?autoconnect=true&resize=scale',
        storePath: env.BRIDGE_STORE || join(home, 'bridge/links.json'),
        idleMs: Number(env.BRIDGE_LINK_IDLE_HOURS || 12) * 3600_000,
        // The frame's shape (the browser viewport auto-browser screenshots), so the
        // phone page can size the frame box before the first frame arrives.
        frameWidth: Number(env.BRIDGE_FRAME_WIDTH) || 480,
        frameHeight: Number(env.BRIDGE_FRAME_HEIGHT) || 1040,
        files: {
            apiToken: join(secrets, 'api-token'),
            vncPassword: join(secrets, 'vnc-password'),
            bridgeToken: join(secrets, 'bridge-token'),
            fillerToken: join(secrets, 'filler-client-token'),
        },
    };
}

export function readSecret(path) {
    const v = readFileSync(path, 'utf8').trim();
    if (!v) throw new Error(`empty secret file ${path}`);
    return v;
}
