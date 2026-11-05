// Which Happy Agent chat a tool call came from. Happy Agent runs one MCP process for all its chats
// and names each call in _meta["claudecode/toolUseId"] with its own call id; the daemon journals
// the agent that made the call before the call reaches us. agentchat.py looks that up read-only in
// the daemon's database (Node 20 has no SQLite).
//
// The chat is the agent's Happy session when it has one (source "happy", the same key the Happy
// CLI's HAPPY_SESSION_ID gives, so the app finds both the same way), else the agent itself
// (source "agent").
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SCRIPT = fileURLToPath(new URL('./agentchat.py', import.meta.url));
const ID = /^[A-Za-z0-9_-]{1,128}$/;

export function createAgentChatLookup({ dbPath, python = 'python3', waitMs = 1500, execFileImpl = execFile, cacheSize = 256 }) {
    const happyOf = new Map(); // agent id -> Happy session id (an agent's Happy session never changes)
    return function lookup(callId, signal) {
        if (typeof callId !== 'string' || !ID.test(callId)) return Promise.resolve(null);
        return new Promise((resolve, reject) => {
            execFileImpl(python, ['-I', SCRIPT, dbPath, callId, String(waitMs)], { timeout: waitMs + 3000, signal, maxBuffer: 64 * 1024 }, (err, stdout) => {
                if (err) return reject(new Error(`agent chat lookup failed: ${err.code ?? err.message}`));
                let r;
                try { r = JSON.parse(String(stdout).trim()); } catch { return reject(new Error('agent chat lookup: bad output')); }
                const agent = typeof r?.agent === 'string' && ID.test(r.agent) ? r.agent : null;
                if (!agent) return resolve(null);
                let happy = typeof r.happy === 'string' && ID.test(r.happy) ? r.happy : null;
                // Keep the first Happy session seen for an agent, so a chat's key never moves.
                if (happyOf.has(agent)) happy = happyOf.get(agent) ?? happy;
                else if (happy) {
                    if (happyOf.size >= cacheSize) happyOf.delete(happyOf.keys().next().value);
                    happyOf.set(agent, happy);
                }
                resolve(happy ? { source: 'happy', id: happy } : { source: 'agent', id: agent });
            });
        });
    };
}
