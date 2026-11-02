#!/usr/bin/env node
/**
 * Happy's Claude desktop hook.
 *
 * One script for every hook the `happy` plugin registers. It is a thin client
 * of the Happy daemon's control server on 127.0.0.1; all logic lives in
 * happy-cli. Contract: docs/plans/happyify-desktop-sync.md.
 *
 *   session-start  POST /desktop/adopt                       (SessionStart)
 *   wait           GET  /desktop/inbox/:sid?wait=600000      (SessionStart, asyncRewake)
 *   busy           POST /desktop/busy                        (UserPromptSubmit)
 *   stop           POST /desktop/idle, then long-poll inbox  (Stop, asyncRewake)
 *   ended          POST /desktop/ended                       (SessionEnd)
 *
 * Guard: exits 0 and prints nothing unless CLAUDE_CODE_ENTRYPOINT is
 * `claude-desktop`, HAPPY_MANAGED is unset, and the daemon answers. A desktop
 * session must never break because Happy is down, so every failure is a
 * silent exit 0. Only a delivered phone message prints: `[Happy] <text>` on
 * stderr and stdout, exit 2, which makes Claude Code start a new turn.
 *
 * Plain Node ESM, node builtins only. Uses node:http rather than fetch because
 * fetch's default headers timeout (300 s) is shorter than the 600 s long-poll.
 */

import { readFileSync } from 'node:fs';
import { request } from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';

const INBOX_WAIT_MS = 600_000;
const SHORT_REQUEST_TIMEOUT_MS = 5_000;
/** Pause before trying a daemon that dropped the inbox wait. */
const DAEMON_RETRY_MS = 2_000;

/**
 * Sends one request to the daemon. Resolves `{status, body}`, or null on any
 * network error or timeout.
 * @param {number} port
 * @param {'GET' | 'POST'} method
 * @param {string} path
 * @param {unknown} payload
 * @param {number} timeoutMs
 * @returns {Promise<{status: number, body: string} | null>}
 */
function daemonRequest(port, method, path, payload, timeoutMs) {
    return new Promise((resolve) => {
        const data = payload === undefined ? undefined : JSON.stringify(payload);
        const req = request({
            host: '127.0.0.1',
            port,
            method,
            path,
            agent: false,
            headers: {
                Connection: 'close',
                ...(data === undefined ? {} : { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }),
            },
        }, (res) => {
            const chunks = [];
            res.on('data', (chunk) => chunks.push(chunk));
            res.on('end', () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') }));
            res.on('error', () => resolve(null));
        });
        req.setTimeout(timeoutMs, () => req.destroy());
        req.on('error', () => resolve(null));
        req.end(data);
    });
}

/** @returns {Promise<string>} */
function readStdin() {
    return new Promise((resolve) => {
        if (process.stdin.isTTY) {
            resolve('');
            return;
        }
        const chunks = [];
        process.stdin.on('data', (chunk) => chunks.push(chunk));
        process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        process.stdin.on('error', () => resolve(''));
    });
}

/** @returns {number | null} the daemon's control port from daemon.state.json */
function readDaemonPort() {
    const configured = process.env.HAPPY_HOME_DIR;
    const homeDir = configured ? configured.replace(/^~(?=\/|$)/, homedir()) : join(homedir(), '.happy');
    const state = JSON.parse(readFileSync(join(homeDir, 'daemon.state.json'), 'utf8'));
    return Number.isInteger(state.httpPort) ? state.httpPort : null;
}

/**
 * Long-polls the inbox. On a message, prints it and sets exit code 2.
 *
 * A dropped connection means the daemon went away (a restart, an upgrade):
 * the wait carries on against whichever daemon comes back, re-reading its
 * port, until the hook's own time is up. Without that, an idle desktop
 * session could not hear from the phone again until its next turn. A 204 is
 * an answer, not a failure: the wait ran out or a newer hook took over.
 * @param {number} port
 * @param {string} claudeSessionId
 */
async function waitForMessage(port, claudeSessionId) {
    const deadline = Date.now() + INBOX_WAIT_MS;
    let currentPort = port;
    while (Date.now() < deadline) {
        const remaining = deadline - Date.now();
        const res = await daemonRequest(
            currentPort,
            'GET',
            `/desktop/inbox/${encodeURIComponent(claudeSessionId)}?wait=${remaining}`,
            undefined,
            remaining + 30_000,
        );
        if (res === null) {
            await new Promise((resolve) => setTimeout(resolve, DAEMON_RETRY_MS));
            try {
                currentPort = readDaemonPort() ?? currentPort;
            } catch {
                // No state file while the daemon restarts; keep the old port.
            }
            continue;
        }
        if (res.status !== 200) {
            return;
        }
        const message = JSON.parse(res.body);
        if (typeof message.text !== 'string') {
            return;
        }
        const line = `[Happy] ${message.text}\n`;
        process.stderr.write(line);
        process.stdout.write(line);
        process.exitCode = 2;
        return;
    }
}

/**
 * Posts one lifecycle event. Returns whether the daemon accepted it.
 * @param {number} port
 * @param {string} path
 * @param {unknown} body
 * @returns {Promise<boolean>}
 */
async function post(port, path, body) {
    const res = await daemonRequest(port, 'POST', path, body, SHORT_REQUEST_TIMEOUT_MS);
    return res !== null && res.status >= 200 && res.status < 300;
}

async function main() {
    if (process.env.CLAUDE_CODE_ENTRYPOINT !== 'claude-desktop' || process.env.HAPPY_MANAGED !== undefined) {
        return;
    }
    const mode = process.argv[2];
    const port = readDaemonPort();
    if (port === null) {
        return;
    }
    const input = JSON.parse(await readStdin());
    const claudeSessionId = input.session_id;
    if (typeof claudeSessionId !== 'string' || claudeSessionId.length === 0) {
        return;
    }

    switch (mode) {
        case 'session-start':
            await post(port, '/desktop/adopt', {
                claudeSessionId,
                transcriptPath: input.transcript_path,
                cwd: input.cwd,
                pid: process.ppid,
            });
            return;
        case 'wait':
            await waitForMessage(port, claudeSessionId);
            return;
        case 'busy':
            await post(port, '/desktop/busy', { claudeSessionId });
            return;
        case 'stop':
            if (await post(port, '/desktop/idle', { claudeSessionId })) {
                await waitForMessage(port, claudeSessionId);
            }
            return;
        case 'ended':
            await post(port, '/desktop/ended', { claudeSessionId });
            return;
        default:
            return;
    }
}

main().catch(() => {
    process.exitCode = 0;
});
