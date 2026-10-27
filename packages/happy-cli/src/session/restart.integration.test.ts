/**
 * Real-process integration test of the "Restart agent" path:
 * app → server → machine RPC `restart-happy-session` → daemon force-stops the
 * session's processes and resumes into the same Happy session.
 *
 * Everything runs for real: a daemon built from this checkout on a scratch
 * HAPPY_HOME_DIR (its own machine, port, state and sessions), real agents
 * (Claude, Codex, OpenCode ACP runner, OpenCode TUI-style headless owner),
 * and the real self-hosted server. The test plays the app: it spawns chats and
 * restarts them through machine RPCs sent via the server, posts encrypted user
 * messages to the server and reads the agent's encrypted replies back.
 *
 * Scenarios (plan, Testing → Integration), each a fresh chat:
 *   1 normal session → restart → same session id, new pid, old pid gone, reply
 *   2 hung owner (SIGSTOP) plus a message sent to it → restart via SIGKILL → reply
 *   3 daemon restarted first (session outlived its daemon) → restart → reply
 *   4 whole session tree killed, message sent while nothing listens → restart → reply
 *   5 OpenCode only: two owners on one OpenCode session → both stopped, one after
 *   6 restart pressed twice at once → one restart (same new pid), one owner
 *   7 after every scenario: no orphaned `opencode serve`/`opencode acp`, no
 *     extra chat, exactly one owner; archiving the restarted chat (as the app
 *     does) stops its owner, so no archive guard swallows it.
 *
 * Only processes this test started are ever signalled, always by explicit pid:
 * a process is ours when its environment carries this test's HAPPY_HOME_DIR.
 * Chats are archived at the end of every test, never deleted.
 *
 * Run: `make -C packages/happy-cli restart-integration` (or
 * `pnpm test:restart-integration`). Knobs: HAPPY_RESTART_IT_RUNS (3),
 * HAPPY_RESTART_IT_FLAVORS (opencode-tui,opencode-acp,claude,codex),
 * HAPPY_RESTART_IT_SCENARIOS (1,2,3,4,5,6), HAPPY_RESTART_IT_SERVER,
 * HAPPY_RESTART_IT_HOME (scratch home; credentials are copied from
 * HAPPY_RESTART_IT_SOURCE_HOME, default ~/.happy, without its machine id).
 */

import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { spawn, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import axios from 'axios';
import { io, type Socket } from 'socket.io-client';
import { decodeBase64, decrypt, encodeBase64, encrypt } from '@/api/encryption';

// --- Configuration -------------------------------------------------------------

const SERVER = process.env.HAPPY_RESTART_IT_SERVER ?? 'https://happy.girthbass.duckdns.org';
const RUNS = parseInt(process.env.HAPPY_RESTART_IT_RUNS ?? '3', 10);
const ALL_FLAVORS = ['opencode-tui', 'opencode-acp', 'claude', 'codex'] as const;
type Flavor = typeof ALL_FLAVORS[number];
const FLAVORS = (process.env.HAPPY_RESTART_IT_FLAVORS ?? ALL_FLAVORS.join(',')).split(',').filter(Boolean) as Flavor[];
const SCENARIOS = (process.env.HAPPY_RESTART_IT_SCENARIOS ?? '1,2,3,4,5,6').split(',').map((s) => parseInt(s, 10));
const SOURCE_HOME = process.env.HAPPY_RESTART_IT_SOURCE_HOME ?? join(homedir(), '.happy');
const HOME = resolve(process.env.HAPPY_RESTART_IT_HOME ?? '/tmp/happy-restart-it/home');
const WORK = join(resolve(HOME, '..'), 'work');
const CLI_ENTRY = resolve(__dirname, '../../dist/index.mjs');
const RESULTS_FILE = join(resolve(HOME, '..'), 'results.jsonl');
const REPLY_TIMEOUT_MS = 180_000;

const BINARIES: Record<Flavor, string> = { 'opencode-tui': 'opencode', 'opencode-acp': 'opencode', claude: 'claude', codex: 'codex' };
function installed(bin: string): boolean {
    if (spawnSync('sh', ['-c', `command -v ${bin}`], { stdio: 'ignore' }).status !== 0) return false;
    if (bin === 'codex') {
        // Happy drives Codex through `codex app-server --listen stdio://` (Codex 0.153+).
        const help = spawnSync('codex', ['app-server', '--help'], { encoding: 'utf8' });
        return `${help.stdout}${help.stderr}`.includes('--listen');
    }
    return true;
}

// --- Environment for everything this test starts ----------------------------------

function childEnv(): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = {};
    for (const [key, value] of Object.entries(process.env)) {
        // Never inherit the session this test may itself run in.
        if (/^(HAPPY_|CLAUDE|CODEX_|OPENCODE_|VITEST|NODE_OPTIONS)/.test(key)) continue;
        env[key] = value;
    }
    return {
        ...env,
        HAPPY_HOME_DIR: HOME,
        HAPPY_SERVER_URL: SERVER,
        HAPPY_WEBAPP_URL: SERVER,
        HAPPY_DAEMON_REANNOUNCE_INTERVAL_MS: '2000',
        HAPPY_DISABLE_CAFFEINATE: '1',
    };
}

// --- Processes -----------------------------------------------------------------------

function readProc(pid: number, file: string): string | null {
    try {
        return readFileSync(`/proc/${pid}/${file}`, 'utf8');
    } catch {
        return null;
    }
}

function cmdline(pid: number): string {
    return (readProc(pid, 'cmdline') ?? '').split('\0').filter(Boolean).join(' ');
}

function alive(pid: number): boolean {
    const stat = readProc(pid, 'stat');
    if (!stat) return false;
    const state = stat.slice(stat.lastIndexOf(')') + 2).split(' ')[0];
    return state !== 'Z' && state !== 'X';
}

function parentPid(pid: number): number | null {
    const stat = readProc(pid, 'stat');
    return stat ? parseInt(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1], 10) : null;
}

/** Live processes carrying this test's HAPPY_HOME_DIR: only these are ever signalled. */
function ourProcesses(): number[] {
    const marker = `HAPPY_HOME_DIR=${HOME}`;
    return readdirSync('/proc').filter((name) => /^\d+$/.test(name)).map(Number).filter((pid) => {
        const env = readProc(pid, 'environ');
        return !!env && env.split('\0').includes(marker) && alive(pid);
    });
}

function isHappyProcess(pid: number): boolean {
    return cmdline(pid).includes(CLI_ENTRY);
}

/** Happy session processes (not the daemon, not a one-shot command). */
function sessionProcesses(): number[] {
    return ourProcesses().filter((pid) => {
        const line = cmdline(pid);
        if (!line.includes(CLI_ENTRY)) return false;
        const args = line.slice(line.indexOf(CLI_ENTRY) + CLI_ENTRY.length).trim().split(' ');
        return args[0] !== 'daemon' && !args.includes('--restart');
    });
}

/** OpenCode servers/ACP agents and Codex app-servers whose Happy owner is gone. */
function orphanedBackends(): number[] {
    return ourProcesses().filter((pid) => {
        const line = cmdline(pid);
        if (isHappyProcess(pid)) return false;
        if (!/opencode.*\b(serve|acp)\b|codex.*app-server/.test(line)) return false;
        let parent = parentPid(pid);
        for (let depth = 0; parent && parent > 1 && depth < 10; depth++) {
            if (isHappyProcess(parent)) return false;
            parent = parentPid(parent);
        }
        return true;
    });
}

function descendants(root: number): number[] {
    const all = readdirSync('/proc').filter((name) => /^\d+$/.test(name)).map(Number);
    const found = new Set<number>([root]);
    let grew = true;
    while (grew) {
        grew = false;
        for (const pid of all) {
            const parent = parentPid(pid);
            if (parent !== null && found.has(parent) && !found.has(pid)) {
                found.add(pid);
                grew = true;
            }
        }
    }
    found.delete(root);
    return [...found];
}

/** Signal a pid this test started (verified by its environment), never anything else. */
function signalOurs(pid: number, signal: NodeJS.Signals): void {
    if (!ourProcesses().includes(pid) && signal !== 'SIGCONT') {
        throw new Error(`refusing to signal ${pid}: not started by this test`);
    }
    try {
        process.kill(pid, signal);
    } catch {
        // already gone
    }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function waitFor<T>(what: string, check: () => T | Promise<T>, timeoutMs = 30_000, intervalMs = 250): Promise<NonNullable<T>> {
    const deadline = Date.now() + timeoutMs;
    while (true) {
        const value = await check();
        if (value) return value as NonNullable<T>;
        if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
        await sleep(intervalMs);
    }
}

// --- Scratch home and daemon -----------------------------------------------------------

type Credentials = { token: string; machineKey: Uint8Array };

function prepareHome(): Credentials {
    mkdirSync(HOME, { recursive: true, mode: 0o700 });
    mkdirSync(WORK, { recursive: true });
    if (!existsSync(join(HOME, 'access.key'))) {
        copyFileSync(join(SOURCE_HOME, 'access.key'), join(HOME, 'access.key'));
    }
    if (!existsSync(join(HOME, 'settings.json'))) {
        // Its own machine: never the source home's machine id, or this daemon
        // would answer the user's machine RPCs.
        writeFileSync(join(HOME, 'settings.json'), JSON.stringify({ schemaVersion: 2, onboardingCompleted: true, serverUrl: SERVER, webappUrl: SERVER }, null, 2), { mode: 0o600 });
    }
    const key = JSON.parse(readFileSync(join(HOME, 'access.key'), 'utf8'));
    if (!key.encryption?.machineKey) throw new Error('scratch access.key has no dataKey encryption');
    return { token: key.token, machineKey: decodeBase64(key.encryption.machineKey) };
}

function daemonState(): { pid: number; httpPort: number } | null {
    try {
        return JSON.parse(readFileSync(join(HOME, 'daemon.state.json'), 'utf8'));
    } catch {
        return null;
    }
}

function machineId(): string {
    return JSON.parse(readFileSync(join(HOME, 'settings.json'), 'utf8')).machineId;
}

async function daemonPost<T>(path: string, body: unknown = {}): Promise<T> {
    const state = daemonState();
    if (!state) throw new Error('scratch daemon not running');
    const response = await axios.post(`http://127.0.0.1:${state.httpPort}${path}`, body, { timeout: 10_000 });
    return response.data as T;
}

async function startDaemon(): Promise<number> {
    const previous = daemonState()?.pid;
    if (previous && alive(previous) && ourProcesses().includes(previous)) return previous;
    spawn(process.execPath, [CLI_ENTRY, 'daemon', 'start'], { env: childEnv(), stdio: 'ignore', detached: true }).unref();
    const state = await waitFor('scratch daemon state', () => {
        const s = daemonState();
        return s && s.pid !== previous && alive(s.pid) ? s : null;
    }, 60_000);
    await waitFor('scratch daemon connected to the server', async () => {
        try {
            return (await daemonPost<{ connected: boolean }>('/status')).connected;
        } catch {
            return false;
        }
    }, 60_000);
    return state.pid;
}

async function stopDaemon(): Promise<void> {
    const state = daemonState();
    if (!state || !alive(state.pid)) return;
    try {
        await daemonPost('/stop');
    } catch {
        // fall through to the signal
    }
    try {
        await waitFor('scratch daemon exit', () => !alive(state.pid), 15_000);
    } catch {
        signalOurs(state.pid, 'SIGKILL');
        await waitFor('scratch daemon exit after SIGKILL', () => !alive(state.pid), 5_000);
    }
}

async function trackedPid(sessionId: string): Promise<number | null> {
    const list = await daemonPost<{ children: Array<{ happySessionId: string; pid: number; startedBy: string }> }>('/list');
    return list.children.find((child) => child.happySessionId === sessionId && alive(child.pid))?.pid ?? null;
}

async function trackedEntry(sessionId: string) {
    const list = await daemonPost<{ children: Array<{ happySessionId: string; pid: number; startedBy: string }> }>('/list');
    return list.children.find((child) => child.happySessionId === sessionId) ?? null;
}

// --- The app's side: server socket, machine and session RPCs, messages ---------------------

let credentials: Credentials;
let socket: Socket;

function connectAsApp(): Promise<Socket> {
    return new Promise((resolveSocket, reject) => {
        const s = io(SERVER, {
            path: '/v1/updates',
            auth: { token: credentials.token, clientType: 'user-scoped' },
            transports: ['websocket'],
            reconnection: true,
        });
        s.once('connect', () => resolveSocket(s));
        s.once('connect_error', reject);
    });
}

async function rpc<T>(method: string, key: Uint8Array, params: unknown, timeoutMs = 120_000): Promise<T> {
    const encrypted = encodeBase64(encrypt(key, 'dataKey', params));
    const answer = await socket.timeout(timeoutMs).emitWithAck('rpc-call', { method, params: encrypted }) as { ok: boolean; result?: string; error?: string };
    if (!answer.ok) throw new Error(answer.error ?? 'RPC failed');
    return decrypt(key, 'dataKey', decodeBase64(answer.result!)) as T;
}

type RestartResult = { type: 'success'; sessionId: string; stoppedPids: number[]; newPid: number } | { type: 'error'; errorMessage: string };

function machineRpc<T>(method: string, params: unknown): Promise<T> {
    return rpc<T>(`${machineId()}:${method}`, credentials.machineKey, params);
}

/** What the app's Restart agent button sends. */
function restartViaServer(sessionId: string): Promise<RestartResult> {
    return machineRpc<RestartResult>('restart-happy-session', { sessionId });
}

type SessionKey = { key: Uint8Array; variant: 'legacy' | 'dataKey' };

function persistedSessions(): Record<string, any> {
    try {
        return JSON.parse(readFileSync(join(HOME, 'sessions.json'), 'utf8')).sessions ?? {};
    } catch {
        return {};
    }
}

function sessionKey(sessionId: string): SessionKey {
    const record = persistedSessions()[sessionId];
    if (!record) throw new Error(`no key for ${sessionId} in the scratch sessions.json`);
    return { key: decodeBase64(record.encryptionKey), variant: record.encryptionVariant };
}

const authHeaders = () => ({ Authorization: `Bearer ${credentials.token}`, 'Content-Type': 'application/json' });

/** Post a user message as the app does; returns its seq. */
async function sendMessage(sessionId: string, text: string): Promise<number> {
    const { key, variant } = sessionKey(sessionId);
    const body = { role: 'user', content: { type: 'text', text }, meta: { sentFrom: 'restart-integration-test' } };
    const response = await axios.post(`${SERVER}/v3/sessions/${encodeURIComponent(sessionId)}/messages`, {
        messages: [{ content: encodeBase64(encrypt(key, variant, body)), localId: randomUUID() }],
    }, { headers: authHeaders(), timeout: 30_000 });
    return response.data.messages[0].seq;
}

async function messagesAfter(sessionId: string, afterSeq: number): Promise<Array<{ seq: number; body: any }>> {
    const { key, variant } = sessionKey(sessionId);
    const out: Array<{ seq: number; body: any }> = [];
    let after = afterSeq;
    while (true) {
        const response = await axios.get(`${SERVER}/v3/sessions/${encodeURIComponent(sessionId)}/messages`, {
            params: { after_seq: after, limit: 100 }, headers: authHeaders(), timeout: 30_000,
        });
        const messages = response.data.messages ?? [];
        for (const message of messages) {
            after = Math.max(after, message.seq);
            if (message.content?.t !== 'encrypted') continue;
            try {
                out.push({ seq: message.seq, body: decrypt(key, variant, decodeBase64(message.content.c)) });
            } catch {
                // undecryptable: ignore
            }
        }
        if (!response.data.hasMore || messages.length === 0) return out;
    }
}

/** A question whose answer is not in the question. */
function question(): { text: string; answer: string } {
    const a = 100 + Math.floor(Math.random() * 800);
    const b = 100 + Math.floor(Math.random() * 800);
    return { text: `Compute ${a} plus ${b}. Reply with only the resulting number, no other text, and do not use any tools.`, answer: String(a + b) };
}

async function awaitReply(sessionId: string, afterSeq: number, answer: string, timeoutMs = REPLY_TIMEOUT_MS): Promise<number> {
    return waitFor(`reply ${answer} in ${sessionId}`, async () => {
        const found = (await messagesAfter(sessionId, afterSeq)).find(({ body }) => body?.role !== 'user' && JSON.stringify(body).includes(answer));
        return found?.seq ?? null;
    }, timeoutMs, 1_500);
}

async function askAndAwait(sessionId: string): Promise<{ seq: number; replySeq: number }> {
    const { text, answer } = question();
    const seq = await sendMessage(sessionId, text);
    const replySeq = await awaitReply(sessionId, seq, answer);
    return { seq, replySeq };
}

async function sessionActive(sessionId: string): Promise<boolean | null> {
    const response = await axios.get(`${SERVER}/v1/sessions`, { headers: authHeaders(), timeout: 30_000 });
    const session = (response.data.sessions ?? []).find((s: any) => s.id === sessionId);
    return session ? !!session.active : null;
}

/** Archive as the app does: ask the session to kill itself, else archive on the server. */
async function archiveAsApp(sessionId: string): Promise<'killSession' | 'server'> {
    try {
        const { key } = sessionKey(sessionId);
        const result = await rpc<{ success: boolean }>(`${sessionId}:killSession`, key, {}, 30_000);
        if (result?.success) return 'killSession';
    } catch {
        // dead CLI: the app falls back to the server archive
    }
    await axios.post(`${SERVER}/v1/sessions/${encodeURIComponent(sessionId)}/archive`, {}, { headers: authHeaders(), timeout: 30_000 });
    return 'server';
}

function opencodeLinks(): Record<string, { happySessionId?: string; updatedAt?: number }> {
    try {
        return JSON.parse(readFileSync(join(HOME, 'opencode-tui', 'happy-sessions.json'), 'utf8'));
    } catch {
        return {};
    }
}

/** The OpenCode session behind a chat: its metadata, else the owner's link file. */
/**
 * The OpenCode session behind a chat: the local record, else the link file,
 * else the server metadata (an ACP runner records it only there).
 */
async function opencodeIdFor(sessionId: string): Promise<string | null> {
    const fromMetadata = persistedSessions()[sessionId]?.metadata?.opencodeSessionId;
    if (fromMetadata) return fromMetadata;
    const linked = Object.entries(opencodeLinks())
        .filter(([, link]) => link.happySessionId === sessionId)
        .sort(([, a], [, b]) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0));
    if (linked[0]) return linked[0][0];
    const response = await axios.get(`${SERVER}/v1/sessions`, { headers: authHeaders(), timeout: 30_000 });
    const session = (response.data.sessions ?? []).find((s: any) => s.id === sessionId);
    if (!session?.metadata) return null;
    const { key, variant } = sessionKey(sessionId);
    const metadata = decrypt(key, variant, decodeBase64(session.metadata)) as { opencodeSessionId?: string } | null;
    return metadata?.opencodeSessionId ?? null;
}

// --- Creating chats per flavor ------------------------------------------------------------------

type Chat = { sessionId: string; flavor: Flavor; workdir: string };

async function newSessionId(before: Set<string>, matches: (id: string, record: any) => boolean, what: string): Promise<string> {
    return waitFor(what, () => Object.entries(persistedSessions()).find(([id, record]) => !before.has(id) && matches(id, record))?.[0] ?? null, 90_000);
}

async function createChat(flavor: Flavor, label: string): Promise<Chat> {
    const workdir = join(WORK, `${flavor}-${label}`);
    mkdirSync(workdir, { recursive: true });
    if (flavor === 'opencode-tui') {
        // The TUI-style owner a terminal starts, headless; started by this test, detached like a terminal job.
        const before = new Set(Object.keys(persistedSessions()));
        const log = openSync(join(workdir, `owner-${Date.now()}.log`), 'a');
        const child = spawn(process.execPath, [CLI_ENTRY, 'opencode', '--headless', '--permission-mode', 'auto'], {
            cwd: workdir, env: childEnv(), stdio: ['ignore', log, log], detached: true,
        });
        child.unref();
        const sessionId = await newSessionId(before, (_, record) => record.metadata?.hostPid === child.pid, `opencode headless owner ${child.pid} to report its session`);
        return { sessionId, flavor, workdir };
    }
    const agent = flavor === 'opencode-acp' ? 'opencode' : flavor;
    const result = await machineRpc<{ type: string; sessionId?: string; errorMessage?: string }>('spawn-happy-session', {
        type: 'spawn-in-directory', directory: workdir, approvedNewDirectoryCreation: true, agent,
    });
    if (result.type !== 'success' || !result.sessionId) throw new Error(`spawn failed: ${JSON.stringify(result)}`);
    return { sessionId: result.sessionId, flavor, workdir };
}

// --- Checks shared by every scenario (scenario 7) ------------------------------------------------

type Evidence = Record<string, unknown>;

async function commonChecks(chat: Chat, createdIds: Set<string>, sessionsBefore: Set<string>, evidence: Evidence): Promise<void> {
    // Exactly one owner for this chat (the only chat this test has running).
    const owners = await waitFor('exactly one session process', () => {
        const procs = sessionProcesses();
        return procs.length === 1 ? procs : null;
    }, 20_000).catch(() => sessionProcesses());
    evidence.ownersAfter = owners.map((pid) => `${pid}: ${cmdline(pid).slice(cmdline(pid).indexOf('index.mjs'))}`);
    expect(owners, 'exactly one Happy process runs the chat').toHaveLength(1);
    // No orphaned backends.
    const orphans = await waitFor('no orphaned backends', () => orphanedBackends().length === 0 ? [] as number[] : null, 15_000).catch(() => orphanedBackends());
    evidence.orphans = orphans.map((pid) => `${pid}: ${cmdline(pid)}`);
    expect(orphans, 'no orphaned opencode serve / acp / codex app-server').toEqual([]);
    // No new chats beyond the ones this scenario made.
    const newIds = Object.keys(persistedSessions()).filter((id) => !sessionsBefore.has(id) && !createdIds.has(id));
    evidence.extraChats = newIds;
    expect(newIds, 'no duplicate chats').toEqual([]);
    // OpenCode: the session's link points at this chat only.
    if (chat.flavor.startsWith('opencode')) {
        const links = opencodeLinks();
        const opencodeId = await opencodeIdFor(chat.sessionId);
        evidence.opencodeSessionId = opencodeId;
        if (opencodeId && links[opencodeId]) expect(links[opencodeId].happySessionId, 'the OpenCode session links to this chat').toBe(chat.sessionId);
    }
}

function expectRestarted(result: RestartResult, chat: Chat, oldPid: number, evidence: Evidence): asserts result is Extract<RestartResult, { type: 'success' }> {
    evidence.restart = result;
    expect(result.type, result.type === 'error' ? result.errorMessage : 'success').toBe('success');
    if (result.type !== 'success') return;
    expect(result.sessionId, 'same Happy session id').toBe(chat.sessionId);
    expect(result.newPid).not.toBe(oldPid);
    expect(alive(oldPid), `old owner ${oldPid} is gone`).toBe(false);
    expect(alive(result.newPid), `new owner ${result.newPid} runs`).toBe(true);
}

// --- The suite ------------------------------------------------------------------------------------

function record(entry: Evidence): void {
    appendFileSync(RESULTS_FILE, JSON.stringify({ at: new Date().toISOString(), ...entry }) + '\n');
}

describe.runIf(process.platform === 'linux')('restart-happy-session against real agents and the real server', () => {
    beforeAll(async () => {
        if (!existsSync(CLI_ENTRY)) throw new Error(`build the CLI first: ${CLI_ENTRY} missing`);
        credentials = prepareHome();
        mkdirSync(resolve(HOME, '..'), { recursive: true });
        const leftovers = sessionProcesses();
        if (leftovers.length > 0) throw new Error(`session processes from an earlier run still live: ${leftovers.join(', ')}`);
        await startDaemon();
        socket = await connectAsApp();
        record({ event: 'start', machineId: machineId(), daemonPid: daemonState()?.pid, server: SERVER, flavors: FLAVORS, scenarios: SCENARIOS, runs: RUNS });
    }, 180_000);

    afterAll(async () => {
        socket?.close();
        // Leave nothing running: the daemon and anything that outlived a failed test.
        for (const pid of sessionProcesses()) signalOurs(pid, 'SIGKILL');
        await stopDaemon();
        await sleep(1_000);
        for (const pid of ourProcesses()) signalOurs(pid, 'SIGKILL');
    }, 60_000);

    for (let run = 1; run <= RUNS; run++) {
        for (const flavor of FLAVORS) {
            for (const scenario of SCENARIOS) {
                const applicable = scenario !== 5 || flavor.startsWith('opencode');
                const available = installed(BINARIES[flavor]);
                it.runIf(applicable && available)(`run ${run} · ${flavor} · scenario ${scenario}`, async () => {
                    const evidence: Evidence = { run, flavor, scenario };
                    const createdIds = new Set<string>();
                    const sessionsBefore = new Set(Object.keys(persistedSessions()));
                    let chat: Chat | null = null;
                    try {
                        await startDaemon();
                        chat = await createChat(flavor, `r${run}-s${scenario}-${Date.now()}`);
                        createdIds.add(chat.sessionId);
                        evidence.sessionId = chat.sessionId;
                        // A first turn, so the agent has a provider session to resume.
                        await askAndAwait(chat.sessionId);
                        const oldPid = await waitFor('tracked owner', () => trackedPid(chat!.sessionId), 30_000);
                        evidence.oldPid = oldPid;
                        evidence.oldTree = descendants(oldPid);
                        const oldTree = [oldPid, ...descendants(oldPid)];

                        let pending: { seq: number; answer: string } | null = null;
                        let result: RestartResult;

                        if (scenario === 1) {
                            result = await restartViaServer(chat.sessionId);
                        } else if (scenario === 2) {
                            signalOurs(oldPid, 'SIGSTOP');
                            const q = question();
                            pending = { seq: await sendMessage(chat.sessionId, q.text), answer: q.answer };
                            await sleep(3_000);
                            const started = Date.now();
                            result = await restartViaServer(chat.sessionId);
                            evidence.restartMs = Date.now() - started;
                            if (result.type === 'success') expect(evidence.restartMs as number, 'stopped by SIGKILL after the grace period').toBeGreaterThanOrEqual(7_000);
                        } else if (scenario === 3) {
                            const oldDaemon = daemonState()!.pid;
                            await stopDaemon();
                            expect(alive(oldPid), 'the session outlives its daemon').toBe(true);
                            const newDaemon = await startDaemon();
                            evidence.daemons = { oldDaemon, newDaemon };
                            evidence.trackedByNewDaemon = await waitFor('new daemon to track the session', () => trackedEntry(chat!.sessionId), 15_000).catch(() => null);
                            result = await restartViaServer(chat.sessionId);
                        } else if (scenario === 4) {
                            // The whole session tree dies; nothing listens for the next message.
                            for (const pid of [...descendants(oldPid), oldPid]) signalOurs(pid, 'SIGKILL');
                            await waitFor('session tree gone', () => oldTree.every((pid) => !alive(pid)), 10_000);
                            await sleep(2_000);
                            const q = question();
                            pending = { seq: await sendMessage(chat.sessionId, q.text), answer: q.answer };
                            await sleep(5_000);
                            const early = (await messagesAfter(chat.sessionId, pending.seq)).some(({ body }) => body?.role !== 'user' && JSON.stringify(body).includes(q.answer));
                            expect(early, 'nobody answered while the agent was down').toBe(false);
                            result = await restartViaServer(chat.sessionId);
                        } else if (scenario === 5) {
                            const opencodeId = await waitFor('OpenCode session id of the chat', () => opencodeIdFor(chat!.sessionId), 30_000);
                            const log = openSync(join(chat.workdir, `second-owner-${Date.now()}.log`), 'a');
                            // A second owner of the same OpenCode session, of the other kind
                            // (the old app Resume put an ACP runner beside a TUI owner). A
                            // `happy opencode --resume` while a TUI owner is live only attaches a
                            // viewer, which is not an owner.
                            const secondArgs = chat.flavor === 'opencode-tui'
                                ? ['opencode', '--acp', '--resume', opencodeId, '--permission-mode', 'auto']
                                : ['opencode', '--resume', opencodeId, '--headless', '--permission-mode', 'auto'];
                            evidence.secondArgs = secondArgs.join(' ');
                            const second = spawn(process.execPath, [CLI_ENTRY, ...secondArgs], {
                                cwd: chat.workdir, env: childEnv(), stdio: ['ignore', log, log], detached: true,
                            });
                            second.unref();
                            // It runs once it has started its own OpenCode backend.
                            await waitFor('second owner running a backend', () => alive(second.pid!) && descendants(second.pid!).some((pid) => /opencode.*\b(serve|acp)\b/.test(cmdline(pid))), 60_000);
                            evidence.secondOwner = second.pid;
                            evidence.ownersBefore = sessionProcesses();
                            expect(sessionProcesses().length, 'two owners before the restart').toBe(2);
                            result = await restartViaServer(chat.sessionId);
                            if (result.type === 'success') {
                                expect(result.stoppedPids, 'both owners stopped').toEqual(expect.arrayContaining([oldPid, second.pid]));
                                expect(alive(second.pid!), 'second owner gone').toBe(false);
                            }
                            // The second owner may have created its own chat; that is the
                            // second owner's doing, not the restart's: record and allow it.
                            for (const id of Object.keys(persistedSessions())) {
                                if (!sessionsBefore.has(id) && persistedSessions()[id]?.metadata?.hostPid === second.pid) {
                                    evidence.secondOwnerChat = id;
                                    createdIds.add(id);
                                }
                            }
                        } else {
                            const [a, b] = await Promise.all([restartViaServer(chat.sessionId), restartViaServer(chat.sessionId)]);
                            evidence.second = b;
                            expect(b, 'the second press gets the first restart').toEqual(a);
                            result = a;
                        }

                        expectRestarted(result, chat, oldPid, evidence);
                        if (result.type !== 'success') return;
                        for (const pid of oldTree) expect(alive(pid), `old process ${pid} (${cmdline(pid)}) is gone`).toBe(false);
                        expect(await trackedPid(chat.sessionId), 'the daemon tracks the new owner').toBe(result.newPid);

                        if (pending) {
                            evidence.pendingReplySeq = await awaitReply(chat.sessionId, pending.seq, pending.answer);
                        }
                        const after = await askAndAwait(chat.sessionId);
                        evidence.replyAfterRestart = after.replySeq;

                        await commonChecks(chat, createdIds, sessionsBefore, evidence);
                        evidence.checks7 = 'pass';

                        // Archiving the restarted chat must stop its owner (no archive guard swallows it).
                        const how = await archiveAsApp(chat.sessionId);
                        evidence.archivedVia = how;
                        await waitFor('owner to exit after archive', () => !alive(result.newPid), 30_000);
                        evidence.pass = true;
                    } catch (error) {
                        evidence.pass = false;
                        evidence.error = error instanceof Error ? error.message : String(error);
                        throw error;
                    } finally {
                        // Archive every chat this test made (never delete) and leave nothing running.
                        for (const id of createdIds) {
                            if (await sessionActive(id).catch(() => null)) {
                                await archiveAsApp(id).catch(() => undefined);
                            }
                        }
                        await sleep(2_000);
                        for (const pid of sessionProcesses()) {
                            signalOurs(pid, 'SIGCONT');
                            signalOurs(pid, 'SIGKILL');
                        }
                        for (const pid of orphanedBackends()) signalOurs(pid, 'SIGKILL');
                        for (const id of createdIds) {
                            if (await sessionActive(id).catch(() => null)) {
                                await axios.post(`${SERVER}/v1/sessions/${encodeURIComponent(id)}/archive`, {}, { headers: authHeaders(), timeout: 30_000 }).catch(() => undefined);
                            }
                        }
                        record(evidence);
                    }
                }, 900_000);
            }
        }
    }
});
