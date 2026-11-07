// Which Happy Agent chat a tool call came from. Happy Agent runs one MCP process for all its chats
// and journals each tool call it starts (the agent that made it, the call's id, tool and
// arguments) before the call reaches us. agentchat.py looks that up read-only in the daemon's
// database (Node 20 has no SQLite):
// - lookup(callId): by the call id, for a client that names it in _meta["claudecode/toolUseId"];
// - lookup.match(name, args): for a client that sends no _meta (Happy Agent as deployed): the one
//   in-flight journaled call of that tool with exactly these arguments. When identical calls are
//   in flight for two agents it answers {ambiguous: true} and names no chat. The arguments only
//   find the daemon's own record of this call; the chat is the agent that record names.
//
// The chat is the agent's Happy session when it has one (source "happy", the same key the Happy
// CLI's HAPPY_SESSION_ID gives, so the app finds both the same way), else the agent itself
// (source "agent").
import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const SCRIPT = fileURLToPath(new URL('./agentchat.py', import.meta.url));
const ID = /^[A-Za-z0-9_-]{1,128}$/;
const TOOL = /^[A-Za-z0-9_.-]{1,128}$/;
// ssh hands the remote shell one command line: only plain words go into it.
const SSH_HOST = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const REMOTE_WORD = /^[A-Za-z0-9._/~+-]{1,512}$/;

// ssh: the host the daemon runs on, when it is not this machine (a Mac's Happy Agent whose MCP
// server is this process, started over ssh). dbPath and python are then paths on that host, and
// the script goes over stdin, so the host needs python3 and nothing else.
export function createAgentChatLookup({ dbPath, python = 'python3', waitMs = 1500, execFileImpl = execFile, cacheSize = 256, ssh = null }) {
    if (ssh !== null && !(SSH_HOST.test(ssh) && REMOTE_WORD.test(dbPath) && REMOTE_WORD.test(python))) throw new Error('agent chat lookup: bad ssh host or path');
    const source = ssh ? readFileSync(SCRIPT, 'utf8') : null;
    const happyOf = new Map(); // agent id -> Happy session id (an agent's Happy session never changes)
    const claimed = []; // call ids already matched to a call, newest last (match mode)
    const identOf = (r) => {
        const agent = typeof r?.agent === 'string' && ID.test(r.agent) ? r.agent : null;
        if (!agent) return null;
        let happy = typeof r.happy === 'string' && ID.test(r.happy) ? r.happy : null;
        // Keep the first Happy session seen for an agent, so a chat's key never moves.
        if (happyOf.has(agent)) happy = happyOf.get(agent) ?? happy;
        else if (happy) {
            if (happyOf.size >= cacheSize) happyOf.delete(happyOf.keys().next().value);
            happyOf.set(agent, happy);
        }
        return happy ? { source: 'happy', id: happy } : { source: 'agent', id: agent };
    };
    const run = (argv, input, signal) => new Promise((resolve, reject) => {
        let cmd = python;
        let args = ['-I', SCRIPT, dbPath, ...argv];
        if (ssh) {
            cmd = 'ssh';
            args = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'LogLevel=ERROR', ssh, '--', python, '-I', '-', dbPath, ...argv];
            // A JSON string is also a valid Python string literal.
            input = (input ? `REQUEST_JSON = ${JSON.stringify(input)}\n` : '') + source;
        }
        const child = execFileImpl(cmd, args, { timeout: waitMs + (ssh ? 8000 : 3000), signal, maxBuffer: 64 * 1024 }, (err, stdout) => {
            if (err) return reject(new Error(`agent chat lookup failed: ${err.code ?? err.message}`));
            try { resolve(JSON.parse(String(stdout).trim())); } catch { reject(new Error('agent chat lookup: bad output')); }
        });
        // The arguments go over stdin, never argv (other processes can read argv).
        if (child?.stdin) { child.stdin.on('error', () => {}); child.stdin.end(input ?? ''); }
    });
    function lookup(callId, signal) {
        if (typeof callId !== 'string' || !ID.test(callId)) return Promise.resolve(null);
        return run([callId, String(waitMs)], '', signal).then(identOf);
    }
    lookup.match = async function match(name, args, signal) {
        if (typeof name !== 'string' || !TOOL.test(name)) return null;
        const r = await run(['--match', String(waitMs)], JSON.stringify({ name, arguments: args && typeof args === 'object' ? args : {}, claimed }), signal);
        if (r?.ambiguous === true) return { ambiguous: true };
        const ident = identOf(r);
        if (!ident) return null;
        if (typeof r.call === 'string') {
            claimed.push(r.call);
            if (claimed.length > 512) claimed.splice(0, claimed.length - 512);
        }
        return ident;
    };
    return lookup;
}
