import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, statSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
    attachOpencodeTui,
    classifyTuiExit,
    findLiveOwner,
    isProcessAlive,
    looksLikeHappyOpencode,
    looksLikeOpencodeServe,
    reapOrphanedServers,
    readTuiState,
    removeTuiState,
    startOpencodeServer,
    writeTuiState,
    type OpencodeServerHandle,
    type OpencodeTuiState,
} from './opencodeProcesses';

/** A stand-in `opencode` executable (see the fixture for its modes). */
const FAKE = join(__dirname, '__fixtures__', 'fake-opencode.cjs');

const started: number[] = [];
const servers: OpencodeServerHandle[] = [];

afterEach(async () => {
    await Promise.all(servers.splice(0).map((server) => server.stop(500)));
    for (const pid of started.splice(0)) {
        if (isProcessAlive(pid)) {
            process.kill(pid, 'SIGKILL');
        }
    }
});

async function waitUntil(check: () => boolean, timeoutMs = 5_000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (!check()) {
        if (Date.now() > deadline) {
            throw new Error('timed out');
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
    }
}

/** A long-running process whose command line reads like `happy opencode`. */
function spawnFakeOwner(): number {
    const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)', 'happy', 'opencode'], { stdio: 'ignore' });
    started.push(child.pid!);
    return child.pid!;
}

function state(overrides: Partial<OpencodeTuiState>): OpencodeTuiState {
    return {
        ownerPid: process.pid,
        serverPid: process.pid,
        url: 'http://127.0.0.1:1',
        password: 'secret',
        cwd: '/tmp',
        opencodeSessionId: 'ses_test',
        happySessionId: 'happy_1',
        startedAt: Date.now(),
        ...overrides,
    };
}

describe('startOpencodeServer', () => {
    it('starts the server in its own process group and stops it by pid', async () => {
        const server = await startOpencodeServer({ bin: process.execPath, args: [FAKE, 'serve'], cwd: tmpdir() });
        servers.push(server);

        expect(server.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
        expect(server.password.length).toBeGreaterThanOrEqual(32);
        // detached: the server leads its own process group, away from the terminal's.
        expect(process.kill(-server.pid, 0)).toBe(true);
        expect((await fetch(server.url)).ok).toBe(true);

        await server.stop();
        expect(await server.exited).toEqual({ code: 0, signal: null });
        expect(isProcessAlive(server.pid)).toBe(false);
    });

    it('escalates to SIGKILL when the server ignores SIGTERM', async () => {
        const server = await startOpencodeServer({
            bin: process.execPath,
            args: [FAKE, 'serve'],
            cwd: tmpdir(),
            env: { ...process.env, FAKE_IGNORE_TERM: '1' },
        });
        await server.stop(200);
        expect(await server.exited).toEqual({ code: null, signal: 'SIGKILL' });
    });

    it('reports a server that dies before it is ready', async () => {
        await expect(startOpencodeServer({ bin: process.execPath, args: [FAKE, 'crash'], cwd: tmpdir() }))
            .rejects.toThrow(/exited \(code 3.*boom/s);
    });
});

describe('attachOpencodeTui', () => {
    it('attaches to the server with the password in the environment only', async () => {
        const out = join(mkdtempSync(join(tmpdir(), 'oc-attach-')), 'out.json');
        const tui = attachOpencodeTui({
            bin: process.execPath,
            url: 'http://127.0.0.1:4096',
            password: 'pw',
            cwd: tmpdir(),
            sessionId: 'ses_1',
            args: [FAKE, 'attach', 'http://127.0.0.1:4096', '--session', 'ses_1'],
            env: { ...process.env, FAKE_ATTACH_OUT: out, FAKE_EXIT_CODE: '0' },
        });
        expect(await tui.exited).toEqual({ code: 0, signal: null });
        const recorded = JSON.parse(readFileSync(out, 'utf8'));
        expect(recorded.password).toBe('pw');
        expect(recorded.argv.join(' ')).not.toContain('pw');
    });

    it('resolves with code 127 when the binary is missing', async () => {
        const tui = attachOpencodeTui({ bin: '/nonexistent/opencode', url: 'http://x', password: 'p', cwd: tmpdir(), sessionId: 's' });
        expect(await tui.exited).toEqual({ code: 127, signal: null });
    });
});

describe('classifyTuiExit', () => {
    const tty = { stdinIsTTY: true, stdoutIsTTY: true, hangupReceived: false };

    it('treats a normal quit as the end of the session', () => {
        expect(classifyTuiExit({ ...tty, exit: { code: 0, signal: null } })).toBe('quit');
        expect(classifyTuiExit({ ...tty, exit: { code: 1, signal: null } })).toBe('quit');
    });

    it('treats a terminal going away as a hangup', () => {
        expect(classifyTuiExit({ ...tty, hangupReceived: true, exit: { code: 0, signal: null } })).toBe('hangup');
        expect(classifyTuiExit({ ...tty, exit: { code: null, signal: 'SIGHUP' } })).toBe('hangup');
        expect(classifyTuiExit({ stdinIsTTY: false, stdoutIsTTY: false, hangupReceived: false, exit: { code: 1, signal: null } })).toBe('hangup');
    });
});

describe('state files', () => {
    it('round-trips with private permissions and is only removed by its owner', () => {
        const dir = join(mkdtempSync(join(tmpdir(), 'oc-state-')), 'opencode-tui');
        const file = writeTuiState(dir, state({ ownerPid: 111 }));
        expect(statSync(file).mode & 0o777).toBe(0o600);
        expect(readTuiState(dir, 'ses_test')).toMatchObject({ ownerPid: 111, password: 'secret' });

        removeTuiState(dir, 'ses_test', 222);
        expect(existsSync(file)).toBe(true);
        removeTuiState(dir, 'ses_test', 111);
        expect(existsSync(file)).toBe(false);
        expect(readTuiState(dir, 'ses_test')).toBeNull();
    });

    it('finds a live owner only when owner and server are both running', async () => {
        const dir = mkdtempSync(join(tmpdir(), 'oc-owner-'));
        const server = await startOpencodeServer({ bin: process.execPath, args: [FAKE, 'serve'], cwd: tmpdir() });
        servers.push(server);
        const ownerPid = spawnFakeOwner();

        writeTuiState(dir, state({ ownerPid, serverPid: server.pid, url: server.url }));
        expect(findLiveOwner(dir, 'ses_test')?.url).toBe(server.url);

        // The test runner itself is not a `happy opencode` process.
        writeTuiState(dir, state({ ownerPid: process.pid, serverPid: server.pid }));
        expect(findLiveOwner(dir, 'ses_test')).toBeNull();
        expect(findLiveOwner(dir, 'ses_missing')).toBeNull();
    });

    it('reaps a server whose owner died, and leaves live owners and foreign pids alone', async () => {
        const dir = mkdtempSync(join(tmpdir(), 'oc-reap-'));
        const orphan = await startOpencodeServer({ bin: process.execPath, args: [FAKE, 'serve'], cwd: tmpdir() });
        const owned = await startOpencodeServer({ bin: process.execPath, args: [FAKE, 'serve'], cwd: tmpdir() });
        servers.push(orphan, owned);
        const deadOwner = spawnFakeOwner();
        process.kill(deadOwner, 'SIGKILL');
        await waitUntil(() => !isProcessAlive(deadOwner));
        const liveOwner = spawnFakeOwner();

        writeTuiState(dir, state({ opencodeSessionId: 'ses_orphan', ownerPid: deadOwner, serverPid: orphan.pid }));
        writeTuiState(dir, state({ opencodeSessionId: 'ses_owned', ownerPid: liveOwner, serverPid: owned.pid }));
        // Dead owner, and a "server" pid that is not opencode serve (this test runner).
        writeTuiState(dir, state({ opencodeSessionId: 'ses_recycled', ownerPid: deadOwner, serverPid: process.pid }));

        expect(reapOrphanedServers(dir)).toEqual([orphan.pid]);
        expect(await orphan.exited).toEqual({ code: 0, signal: null });
        expect(isProcessAlive(owned.pid)).toBe(true);
        expect(readTuiState(dir, 'ses_orphan')).toBeNull();
        expect(readTuiState(dir, 'ses_recycled')).toBeNull();
        expect(readTuiState(dir, 'ses_owned')).not.toBeNull();
    });

    it('recognises the command lines it may signal', () => {
        expect(looksLikeOpencodeServe('/home/u/.opencode/bin/opencode serve --hostname 127.0.0.1 --port 0')).toBe(true);
        expect(looksLikeOpencodeServe('/home/u/.opencode/bin/opencode attach http://x')).toBe(false);
        expect(looksLikeOpencodeServe(null)).toBe(false);
        expect(looksLikeHappyOpencode('node --no-warnings /x/happy-cli/dist/index.mjs opencode --resume ses_1')).toBe(true);
        expect(looksLikeHappyOpencode('node /x/happy-cli/dist/index.mjs claude')).toBe(false);
    });
});
