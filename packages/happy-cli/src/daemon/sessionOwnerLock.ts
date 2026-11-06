/**
 * One live owner per Happy session.
 *
 * Every process that attaches to a session (a runner, a desktop attach)
 * first takes `<happyHomeDir>/sessions/<session id>.lock`. The file names the
 * owning process by pid and start time, so a recycled pid is never mistaken
 * for the owner. A second process that finds a live owner must not attach.
 *
 * The lock is created atomically (temp file + link, which fails with EEXIST
 * like O_EXCL), so it never exists half-written. A stale lock (dead owner,
 * recycled pid, unreadable content) is taken over under a short-lived guard
 * file, so two processes racing for the same stale lock produce one winner.
 */
import {
    linkSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    statSync,
    unlinkSync,
    writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { configuration } from '@/configuration';
import { isPidAlive as defaultIsPidAlive } from './sessionLiveness';
import { getProcessStartTime, type ProcessStartTime } from '@/utils/processStartTime';

export interface SessionOwnerRecord {
    pid: number;
    /** From getProcessStartTime; null when it could not be read. */
    startTime: string | null;
    sessionId: string;
    acquiredAt: number;
    cliVersion: string;
    startedBy: string;
}

export type SessionOwnershipResult =
    | { acquired: true; release: () => void }
    | { acquired: false; owner: SessionOwnerRecord };

export interface SessionOwnerLockDeps {
    locksDir: () => string;
    pid: () => number;
    getStartTime: (pid: number) => ProcessStartTime;
    isPidAlive: (pid: number) => boolean;
    now: () => number;
    cliVersion: string;
    startedBy: string;
    /** Test hook: runs inside the takeover guard, before the stale lock is replaced. */
    onTakeoverGuardHeld?: () => void;
}

const SESSION_ID_PATTERN = /^[A-Za-z0-9_-]+$/;
const TAKEOVER_GUARD_STALE_MS = 10_000;
const MAX_ATTEMPTS = 20;

function defaultStartedBy(): string {
    const index = process.argv.indexOf('--started-by');
    const value = index === -1 ? undefined : process.argv[index + 1];
    return value === 'daemon' ? 'daemon' : 'terminal';
}

export function defaultSessionOwnerLockDeps(): SessionOwnerLockDeps {
    return {
        locksDir: () => configuration.sessionLocksDir,
        pid: () => process.pid,
        getStartTime: (pid) => getProcessStartTime(pid),
        isPidAlive: (pid) => defaultIsPidAlive(pid),
        now: () => Date.now(),
        cliVersion: configuration.currentCliVersion,
        startedBy: defaultStartedBy(),
    };
}

function resolveDeps(deps?: Partial<SessionOwnerLockDeps>): SessionOwnerLockDeps {
    return { ...defaultSessionOwnerLockDeps(), ...deps };
}

export function isValidSessionId(sessionId: string): boolean {
    return SESSION_ID_PATTERN.test(sessionId);
}

function assertValidSessionId(sessionId: string): void {
    if (!isValidSessionId(sessionId)) {
        throw new Error(`Invalid session id for owner lock: ${JSON.stringify(sessionId)}`);
    }
}

export function sessionLockPath(sessionId: string, deps?: Partial<SessionOwnerLockDeps>): string {
    assertValidSessionId(sessionId);
    return join(resolveDeps(deps).locksDir(), `${sessionId}.lock`);
}

/** 'missing' when there is no lock file; 'corrupt' when it cannot be parsed. */
function readLockFile(path: string): SessionOwnerRecord | 'missing' | 'corrupt' {
    let raw: string;
    try {
        raw = readFileSync(path, 'utf8');
    } catch (error) {
        return (error as NodeJS.ErrnoException).code === 'ENOENT' ? 'missing' : 'corrupt';
    }
    try {
        const parsed = JSON.parse(raw) as Partial<SessionOwnerRecord>;
        if (!parsed || !Number.isSafeInteger(parsed.pid) || (parsed.pid as number) <= 0 || typeof parsed.sessionId !== 'string') {
            return 'corrupt';
        }
        return {
            pid: parsed.pid as number,
            startTime: typeof parsed.startTime === 'string' ? parsed.startTime : null,
            sessionId: parsed.sessionId,
            acquiredAt: typeof parsed.acquiredAt === 'number' ? parsed.acquiredAt : 0,
            cliVersion: typeof parsed.cliVersion === 'string' ? parsed.cliVersion : 'unknown',
            startedBy: typeof parsed.startedBy === 'string' ? parsed.startedBy : 'unknown',
        };
    } catch {
        return 'corrupt';
    }
}

function sameStartTime(a: string | null | undefined, b: string | null | undefined): boolean {
    // Only a mismatch between two known values proves a different process.
    if (typeof a !== 'string' || typeof b !== 'string') return true;
    return a === b;
}

/** The recorded owner is still the process that took the lock. */
export function isOwnerAlive(owner: SessionOwnerRecord, deps?: Partial<SessionOwnerLockDeps>): boolean {
    const d = resolveDeps(deps);
    if (!d.isPidAlive(owner.pid)) return false;
    const current = d.getStartTime(owner.pid);
    if (current === null) return false;
    return sameStartTime(owner.startTime, current);
}

/**
 * Whether `pid` is still the process that had `startTime`. Daemon tracking
 * entries without a child handle use this so a reused pid is not mistaken
 * for the session owner.
 */
export function isProcessIdentityAlive(pid: number, startTime: string | null, deps?: Partial<SessionOwnerLockDeps>): boolean {
    return isOwnerAlive({ pid, startTime, sessionId: '', acquiredAt: 0, cliVersion: '', startedBy: '' }, deps);
}

function isOwnRecord(record: SessionOwnerRecord, ownPid: number, ownStartTime: string | null): boolean {
    return record.pid === ownPid && sameStartTime(record.startTime, ownStartTime);
}

function sleepSync(ms: number): void {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/** Create `path` holding `content` atomically; false when it already exists. */
function linkExclusive(path: string, content: string): boolean {
    const tempPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
    writeFileSync(tempPath, content, { mode: 0o600 });
    try {
        linkSync(tempPath, path);
        return true;
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'EEXIST') return false;
        throw error;
    } finally {
        try { unlinkSync(tempPath); } catch { /* already gone */ }
    }
}

function unlinkQuietly(path: string): void {
    try { unlinkSync(path); } catch { /* already gone */ }
}

/**
 * Hold the takeover guard for `lockPath` while running `fn`. Returns
 * 'busy' when another process holds a fresh guard.
 */
function withTakeoverGuard<T>(lockPath: string, deps: SessionOwnerLockDeps, fn: () => T): T | 'busy' {
    const guardPath = `${lockPath}.takeover`;
    const token = `${deps.pid()}:${randomUUID()}`;
    if (!linkExclusive(guardPath, token)) {
        try {
            const age = deps.now() - statSync(guardPath).mtimeMs;
            if (age > TAKEOVER_GUARD_STALE_MS) {
                // The guard holder died mid-takeover; clear it and let the caller retry.
                unlinkQuietly(guardPath);
            }
        } catch {
            // Released between our attempt and the stat.
        }
        return 'busy';
    }
    try {
        return fn();
    } finally {
        try {
            if (readFileSync(guardPath, 'utf8') === token) unlinkSync(guardPath);
        } catch { /* already gone */ }
    }
}

/**
 * Take exclusive ownership of a session for this process.
 *
 * Re-entrant: a process that already owns the lock gets `acquired: true`
 * again. A live owner elsewhere gives `acquired: false` with its record.
 */
export function acquireSessionOwnership(sessionId: string, depsOverride?: Partial<SessionOwnerLockDeps>): SessionOwnershipResult {
    assertValidSessionId(sessionId);
    const deps = resolveDeps(depsOverride);
    const dir = deps.locksDir();
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const lockPath = join(dir, `${sessionId}.lock`);

    const ownPid = deps.pid();
    const startTime = deps.getStartTime(ownPid);
    const ownStartTime = typeof startTime === 'string' ? startTime : null;
    const record: SessionOwnerRecord = {
        pid: ownPid,
        startTime: ownStartTime,
        sessionId,
        acquiredAt: deps.now(),
        cliVersion: deps.cliVersion,
        startedBy: deps.startedBy,
    };
    const content = JSON.stringify(record);

    const release = () => releaseIfOwned(lockPath, ownPid, ownStartTime);
    const acquired = (): SessionOwnershipResult => ({ acquired: true, release });

    let lastOwner: SessionOwnerRecord | null = null;
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        if (linkExclusive(lockPath, content)) return acquired();

        const existing = readLockFile(lockPath);
        if (existing === 'missing') continue;
        if (existing !== 'corrupt') {
            if (isOwnRecord(existing, ownPid, ownStartTime)) return acquired();
            if (isOwnerAlive(existing, deps)) return { acquired: false, owner: existing };
            lastOwner = existing;
        }

        // Stale: dead owner, recycled pid, or unreadable content.
        const outcome = withTakeoverGuard(lockPath, deps, (): SessionOwnershipResult | 'retry' => {
            const current = readLockFile(lockPath);
            if (current !== 'missing' && current !== 'corrupt') {
                if (isOwnRecord(current, ownPid, ownStartTime)) return acquired();
                if (isOwnerAlive(current, deps)) return { acquired: false, owner: current };
            }
            deps.onTakeoverGuardHeld?.();
            if (current !== 'missing') unlinkQuietly(lockPath);
            if (!linkExclusive(lockPath, content)) return 'retry';
            const verify = readLockFile(lockPath);
            if (verify !== 'missing' && verify !== 'corrupt' && isOwnRecord(verify, ownPid, ownStartTime)) {
                return acquired();
            }
            return 'retry';
        });
        if (outcome !== 'busy' && outcome !== 'retry') return outcome;
        sleepSync(Math.min(25 * (attempt + 1), 200));
    }

    // Could not settle the race; report whoever holds it now.
    const final = readLockFile(lockPath);
    if (final !== 'missing' && final !== 'corrupt') {
        if (isOwnRecord(final, ownPid, ownStartTime)) return acquired();
        return { acquired: false, owner: final };
    }
    if (lastOwner) return { acquired: false, owner: lastOwner };
    throw new Error(`Could not acquire the owner lock for session ${sessionId}`);
}

function releaseIfOwned(lockPath: string, ownPid: number, ownStartTime: string | null): void {
    const current = readLockFile(lockPath);
    if (current === 'missing' || current === 'corrupt') return;
    if (!isOwnRecord(current, ownPid, ownStartTime)) return;
    unlinkQuietly(lockPath);
}

/** The live owner of a session, or null when none (no lock or a stale one). */
export function readLiveSessionOwner(sessionId: string, deps?: Partial<SessionOwnerLockDeps>): SessionOwnerRecord | null {
    if (!isValidSessionId(sessionId)) return null;
    const record = readLockFile(join(resolveDeps(deps).locksDir(), `${sessionId}.lock`));
    if (record === 'missing' || record === 'corrupt') return null;
    return isOwnerAlive(record, deps) ? record : null;
}

/** Whether `pid` is the live owner recorded in a session's lock. */
export function isSessionLockHeldBy(sessionId: string, pid: number, deps?: Partial<SessionOwnerLockDeps>): boolean {
    const owner = readLiveSessionOwner(sessionId, deps);
    return owner !== null && owner.pid === pid;
}

const ownStartTimes = new Map<number, string | null>();

/**
 * Whether the session's lock still names this process. Cheap enough to ask
 * before each forwarded message: one small file read, with this process's
 * own start time looked up once.
 */
export function isSessionLockHeldByThisProcess(sessionId: string, deps?: Partial<SessionOwnerLockDeps>): boolean {
    if (!isValidSessionId(sessionId)) return false;
    const d = resolveDeps(deps);
    const record = readLockFile(join(d.locksDir(), `${sessionId}.lock`));
    if (record === 'missing' || record === 'corrupt') return false;
    const ownPid = d.pid();
    if (record.pid !== ownPid) return false;
    let ownStartTime = deps?.getStartTime ? undefined : ownStartTimes.get(ownPid);
    if (ownStartTime === undefined) {
        const current = d.getStartTime(ownPid);
        ownStartTime = typeof current === 'string' ? current : null;
        if (!deps?.getStartTime) ownStartTimes.set(ownPid, ownStartTime);
    }
    return isOwnRecord(record, ownPid, ownStartTime);
}

export function listLiveSessionOwners(deps?: Partial<SessionOwnerLockDeps>): SessionOwnerRecord[] {
    const dir = resolveDeps(deps).locksDir();
    let names: string[];
    try {
        names = readdirSync(dir);
    } catch {
        return [];
    }
    const owners: SessionOwnerRecord[] = [];
    for (const name of names) {
        if (!name.endsWith('.lock')) continue;
        const owner = readLiveSessionOwner(name.slice(0, -'.lock'.length), deps);
        if (owner) owners.push(owner);
    }
    return owners;
}

// ─── Process-level ownership ───

// Indirect so a stubbed exit (tests) does not make the code after it unreachable for the compiler.
const exitProcess = (code: number): void => { process.exit(code); };

const heldReleases = new Map<string, () => void>();
let exitHookInstalled = false;

function installExitHook(): void {
    if (exitHookInstalled) return;
    exitHookInstalled = true;
    process.on('exit', () => releaseAllSessionOwnership());
}

/**
 * Claim a session for this process or exit. A conflict means another live
 * process is already serving this session: this one must not open a socket
 * or send anything (in particular no session-end), so it exits quietly.
 */
export function claimSessionOwnershipOrExit(sessionId: string, deps?: Partial<SessionOwnerLockDeps>): () => void {
    const existing = heldReleases.get(sessionId);
    const result = acquireSessionOwnership(sessionId, deps);
    if (!result.acquired) {
        const message = `Session ${sessionId} is already running (pid ${result.owner.pid}); not attaching.`;
        console.error(message);
        exitProcess(0);
        // Only reached when exit is stubbed (tests): still never attach.
        throw new Error(message);
    }
    if (existing) return existing;
    const release = () => {
        if (heldReleases.get(sessionId) === release) heldReleases.delete(sessionId);
        result.release();
    };
    heldReleases.set(sessionId, release);
    installExitHook();
    return release;
}

export function releaseSessionOwnership(sessionId: string): void {
    heldReleases.get(sessionId)?.();
}

export function releaseAllSessionOwnership(): void {
    for (const release of [...heldReleases.values()]) release();
}
