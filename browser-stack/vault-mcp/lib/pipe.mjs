// The pipe runner: the one place a vault value is in an agent-side process.
// The filler hands vault-mcp {argv, value} for a root-allowlisted target
// (policy pipe_targets); this spawns argv (no shell), writes the value to
// its stdin, closes stdin, and returns only the command's exit status and
// its output, with every form of the value scrubbed out. The value is never
// an argument, never in the environment and never in a result.
import { spawn } from 'node:child_process';
import { variantsOf } from '../../browser/filler/lib/scrub.mjs';

export const PIPE_TIMEOUT_MS = 60_000;
export const PIPE_MAX_OUTPUT = 64 * 1024;

/** Replace every form of value in s (longest first) with [secret:<label>]. */
export function scrubValue(s, value, label = 'value') {
    if (typeof s !== 'string' || !s || typeof value !== 'string' || !value) return s;
    let out = s;
    for (const v of variantsOf(value)) if (out.includes(v)) out = out.split(v).join(`[secret:${label}]`);
    return out;
}

/**
 * Run argv with value on stdin. Resolves {exit_code, signal, timed_out,
 * truncated, stdout, stderr}; rejects only when the command cannot start.
 */
export function runPipe({ argv, value, label = 'value', timeoutMs = PIPE_TIMEOUT_MS, maxOutput = PIPE_MAX_OUTPUT, env = process.env, spawnImpl = spawn }) {
    if (!Array.isArray(argv) || !argv.length || argv.some((a) => typeof a !== 'string' || a.includes('\0'))) {
        return Promise.reject(new Error('pipe: the filler sent no usable command'));
    }
    if (typeof value !== 'string' || !value) return Promise.reject(new Error('pipe: the filler sent no value'));
    const input = Buffer.from(value, 'utf8');
    return new Promise((resolve, reject) => {
        let child;
        try {
            child = spawnImpl(argv[0], argv.slice(1), { stdio: ['pipe', 'pipe', 'pipe'], shell: false, env, windowsHide: true });
        } catch (err) {
            input.fill(0);
            return reject(new Error(`pipe: cannot run ${argv[0]}: ${err.code || err.message}`));
        }
        const out = { stdout: [], stderr: [] };
        let size = 0; let truncated = false; let timedOut = false; let done = false;
        const take = (which) => (chunk) => {
            if (size >= maxOutput) { truncated = true; return; }
            const room = maxOutput - size;
            const part = chunk.length > room ? chunk.subarray(0, room) : chunk;
            if (part.length < chunk.length) truncated = true;
            size += part.length;
            out[which].push(Buffer.from(part));
        };
        child.stdout.on('data', take('stdout'));
        child.stderr.on('data', take('stderr'));
        const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, timeoutMs);
        const finish = (fn) => { if (done) return; done = true; clearTimeout(timer); input.fill(0); fn(); };
        child.on('error', (err) => finish(() => reject(new Error(`pipe: cannot run ${argv[0]}: ${err.code || err.message}`))));
        child.on('close', (code, signal) => finish(() => {
            const text = (which) => {
                const b = Buffer.concat(out[which]);
                const s = scrubValue(b.toString('utf8'), value, label);
                b.fill(0);
                return s;
            };
            resolve({ exit_code: code, signal: signal || null, timed_out: timedOut, truncated, stdout: text('stdout'), stderr: text('stderr') });
        }));
        child.stdin.on('error', () => {}); // a command that exits without reading stdin
        child.stdin.end(input);
    });
}
