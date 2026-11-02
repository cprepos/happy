/**
 * Tests for the Claude desktop plugin's hook script
 * (claude-desktop-plugin/plugins/happy/scripts/hook.mjs).
 *
 * The script runs as a real child process against a real local HTTP server
 * that stands in for the daemon's control server, with a throwaway
 * HAPPY_HOME_DIR holding its daemon.state.json.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { spawn } from 'node:child_process';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import type { AddressInfo } from 'node:net';
import { projectPath } from '@/projectPath';

const hookScript = resolve(projectPath(), 'claude-desktop-plugin', 'plugins', 'happy', 'scripts', 'hook.mjs');

interface RecordedRequest {
    method: string;
    url: string;
    body: unknown;
}

type Handler = (req: RecordedRequest, res: ServerResponse) => void;

interface HookResult {
    code: number | null;
    stdout: string;
    stderr: string;
    pid: number;
}

const hookInput = {
    session_id: 'claude-session-1',
    transcript_path: '/tmp/transcript.jsonl',
    cwd: '/tmp/project',
    hook_event_name: 'SessionStart',
};

function runHook(mode: string, env: Record<string, string>, input: unknown = hookInput): Promise<HookResult> {
    return new Promise((resolvePromise, reject) => {
        const child = spawn(process.execPath, [hookScript, mode], {
            env: { PATH: process.env.PATH ?? '', ...env },
            stdio: ['pipe', 'pipe', 'pipe'],
        });
        let stdout = '';
        let stderr = '';
        child.stdout.on('data', (chunk) => { stdout += chunk; });
        child.stderr.on('data', (chunk) => { stderr += chunk; });
        child.on('error', reject);
        child.on('close', (code) => resolvePromise({ code, stdout, stderr, pid: child.pid ?? -1 }));
        child.stdin.end(JSON.stringify(input));
    });
}

describe('claude desktop hook.mjs', () => {
    let homeDir: string;
    let server: Server;
    let port: number;
    let requests: RecordedRequest[];
    let handler: Handler;

    beforeEach(async () => {
        homeDir = mkdtempSync(join(tmpdir(), 'happy-desktop-hook-'));
        requests = [];
        handler = (_req, res) => {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: true }));
        };
        server = createServer((req: IncomingMessage, res: ServerResponse) => {
            let raw = '';
            req.on('data', (chunk) => { raw += chunk; });
            req.on('end', () => {
                const recorded: RecordedRequest = {
                    method: req.method ?? '',
                    url: req.url ?? '',
                    body: raw.length > 0 ? JSON.parse(raw) : undefined,
                };
                requests.push(recorded);
                handler(recorded, res);
            });
        });
        await new Promise<void>((done) => server.listen(0, '127.0.0.1', done));
        port = (server.address() as AddressInfo).port;
        writeFileSync(join(homeDir, 'daemon.state.json'), JSON.stringify({ pid: process.pid, httpPort: port }));
    });

    afterEach(async () => {
        server.closeAllConnections();
        await new Promise<void>((done) => server.close(() => done()));
        rmSync(homeDir, { recursive: true, force: true });
    });

    const desktopEnv = (): Record<string, string> => ({
        CLAUDE_CODE_ENTRYPOINT: 'claude-desktop',
        HAPPY_HOME_DIR: homeDir,
    });

    it('does nothing outside the desktop entrypoint', async () => {
        const result = await runHook('session-start', { ...desktopEnv(), CLAUDE_CODE_ENTRYPOINT: 'cli' });
        expect(result).toMatchObject({ code: 0, stdout: '', stderr: '' });
        expect(requests).toEqual([]);
    });

    it('does nothing in a Claude that Happy spawned', async () => {
        const result = await runHook('stop', { ...desktopEnv(), HAPPY_MANAGED: '1' });
        expect(result).toMatchObject({ code: 0, stdout: '', stderr: '' });
        expect(requests).toEqual([]);
    });

    it('exits 0 silently when the daemon is down', async () => {
        server.closeAllConnections();
        await new Promise<void>((done) => server.close(() => done()));
        const result = await runHook('stop', desktopEnv());
        expect(result).toMatchObject({ code: 0, stdout: '', stderr: '' });
        // Reopen so afterEach can close it again.
        server.listen(0, '127.0.0.1');
    });

    it('exits 0 silently when there is no daemon state file', async () => {
        rmSync(join(homeDir, 'daemon.state.json'));
        const result = await runHook('session-start', desktopEnv());
        expect(result).toMatchObject({ code: 0, stdout: '', stderr: '' });
        expect(requests).toEqual([]);
    });

    it('session-start posts the adopt body with the parent pid', async () => {
        handler = (_req, res) => {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ happySessionId: 'happy-1' }));
        };
        const result = await runHook('session-start', desktopEnv());
        expect(result).toMatchObject({ code: 0, stdout: '', stderr: '' });
        expect(requests).toEqual([{
            method: 'POST',
            url: '/desktop/adopt',
            body: {
                claudeSessionId: 'claude-session-1',
                transcriptPath: '/tmp/transcript.jsonl',
                cwd: '/tmp/project',
                // The hook's parent is this test process, standing in for claude.
                pid: process.pid,
            },
        }]);
    });

    it('busy and ended post the session id', async () => {
        expect((await runHook('busy', desktopEnv())).code).toBe(0);
        expect((await runHook('ended', desktopEnv())).code).toBe(0);
        expect(requests).toEqual([
            { method: 'POST', url: '/desktop/busy', body: { claudeSessionId: 'claude-session-1' } },
            { method: 'POST', url: '/desktop/ended', body: { claudeSessionId: 'claude-session-1' } },
        ]);
    });

    it('stop posts idle, then delivers an inbox message with exit 2', async () => {
        handler = (req, res) => {
            if (req.url.startsWith('/desktop/inbox/')) {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ localId: 'local-1', text: 'hi' }));
                return;
            }
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: true }));
        };
        const result = await runHook('stop', desktopEnv());
        expect(result).toMatchObject({ code: 2, stdout: '[Happy] hi\n', stderr: '[Happy] hi\n' });
        expect(requests).toEqual([
            { method: 'POST', url: '/desktop/idle', body: { claudeSessionId: 'claude-session-1' } },
            { method: 'GET', url: '/desktop/inbox/claude-session-1?wait=600000', body: undefined },
        ]);
    });

    it('wait long-polls the inbox and exits 0 on 204', async () => {
        handler = (_req, res) => {
            res.writeHead(204);
            res.end();
        };
        const result = await runHook('wait', desktopEnv());
        expect(result).toMatchObject({ code: 0, stdout: '', stderr: '' });
        expect(requests).toHaveLength(1);
        expect(requests[0]).toMatchObject({ method: 'GET', body: undefined });
        // The wait asks for the hook's remaining time, at most 600 s.
        const wait = Number(new URL(requests[0].url, 'http://x').searchParams.get('wait'));
        expect(new URL(requests[0].url, 'http://x').pathname).toBe('/desktop/inbox/claude-session-1');
        expect(wait).toBeGreaterThan(590_000);
        expect(wait).toBeLessThanOrEqual(600_000);
    });

    it('keeps waiting across a daemon restart and delivers from the new daemon', async () => {
        // The restarted daemon comes up on another port and has the message.
        const restarted = createServer((req, res) => {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ localId: 'L1', text: 'after the restart' }));
            void req;
        });
        await new Promise<void>((done) => restarted.listen(0, '127.0.0.1', done));
        const restartedPort = (restarted.address() as AddressInfo).port;
        // The old daemon drops the long-poll as it goes away.
        handler = (_req, res) => {
            writeFileSync(join(homeDir, 'daemon.state.json'), JSON.stringify({ pid: process.pid, httpPort: restartedPort }));
            res.socket?.destroy();
        };
        try {
            const result = await runHook('wait', desktopEnv());
            expect(result).toMatchObject({ code: 2, stdout: '[Happy] after the restart\n' });
            expect(requests.map((r) => new URL(r.url, 'http://x').pathname)).toEqual(['/desktop/inbox/claude-session-1']);
        } finally {
            restarted.closeAllConnections();
            await new Promise<void>((done) => restarted.close(() => done()));
        }
    });

    it('stop does not wait when idle is rejected', async () => {
        handler = (_req, res) => {
            res.writeHead(404);
            res.end();
        };
        const result = await runHook('stop', desktopEnv());
        expect(result).toMatchObject({ code: 0, stdout: '', stderr: '' });
        expect(requests.map((r) => r.url)).toEqual(['/desktop/idle']);
    });
});
