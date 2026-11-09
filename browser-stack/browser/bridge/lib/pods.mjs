// The pod manager: one browser pod (a browser-node plus its own controller) per chat.
//
// The bridge never touches Docker. It asks the launcher (launcher/launcher.mjs) over a unix socket
// to start, stop and list pods and to move a chat's saved login in and out of a pod, and it talks
// to each pod's controller on that pod's 127.0.0.1 port. What it keeps here:
//
//   pods   slot -> {slot, podId, vncPassword, ports, state, chatKey}
//          state: starting | ready (a warm spare, no chat) | assigned | stopping
//   chats  chatKey -> {chatKey, source, linkId, slot, podId, sessionId, state, lastAgentAt,
//          lastViewerAt, hasAuth, forkChecked}
//          state: none | starting | running | asleep | crashed
//          forkChecked: a forked chat's one try at its parent's login has been made
//
// chatKey is the 32-hex chat hash (sha256(source + ':' + id), first 32 chars), which is also the
// launcher's chat_hash: the chat's saved login lives under data/chats/<chatKey>/auth.
//
// Lifecycle (docs/per-chat-pods-plan.md, section B):
//   ensure    a warm spare if one is ready (or about to be), else a cold start in a free slot,
//             else the least recently active pod that nobody holds is put to sleep and its slot
//             reused; if every pod is held or busy: "all N browsers are busy". Concurrent calls
//             for one chat share one start. The spare pool refills in the background.
//   stop      save the login (auth profile "happy-chat") -> stash it in the chat's directory ->
//             close the session -> stop the pod -> the chat is asleep. Used by the idle timer, by
//             eviction, by /api/pod/close, by the user putting it to sleep (/live/<id>/sleep) and by the
//             user ending it (/live/<id>/end). The next start reopens the link's last page, except
//             after the user's End: that one keeps the login and starts on a new page (chat.fresh).
//   idle      a pod whose chat has had neither an agent call nor a viewer request (live page,
//             /state, frame, noVNC file or open noVNC socket) for idleMs (60 min by default) is
//             stopped, unless it is protected: its link is held (the user has control, or the
//             agent waits in wait_for_human), it has an approval pending on its controller, or
//             something in the bridge holds it (hold()). Protection lapses after protectMaxMs
//             without any activity, so a forgotten approval cannot pin a pod for ever. Eviction
//             (all maxPods slots taken) skips protected pods too, longest idle first.
//   health    every healthMs: launcher list plus /readyz per pod. Two failures in a row and the
//             pod is stopped; an assigned pod's chat turns crashed, and its next call gets a new
//             pod and session under the same link.
//   fork      a forked or side chat (ensure's forkedFrom: the parent's chat key) with no saved
//             login of its own gets a copy of the parent's on its first browser use: the parent's
//             running pod is saved first, then the launcher copies (copy_auth), never over a login
//             the chat already has. Tried once per chat; after that its own saves take over.
//   reconcile at boot, pods recorded as assigned whose containers are still up and ready are
//             adopted; everything else the launcher lists is stopped.
import { randomBytes } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname } from 'node:path';
import { createAutoBrowserClient } from './autobrowser.mjs';

export const CHAT_KEY = /^[0-9a-f]{32}$/;
export const AUTH_PROFILE = 'happy-chat';
const HELD = new Set(['user', 'takeover']);

export class PodError extends Error {
    constructor(message, status = 503, code = 'pod_error') {
        super(message);
        this.status = status;
        this.code = code;
    }
}

const short = (err) => String(err?.message || err).split('\n')[0].slice(0, 200);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── Launcher client ───────────────────────────────────────────────────────
// One connection per request: write a JSON line, read the JSON line that answers it.
export function createLauncherClient(socketPath, { timeoutMs = 120_000 } = {}) {
    let seq = 0;
    return {
        call(op, args = {}) {
            const id = ++seq;
            return new Promise((resolve, reject) => {
                const conn = connect(socketPath);
                let buf = '';
                let done = false;
                const finish = (err, value) => {
                    if (done) return;
                    done = true;
                    clearTimeout(timer);
                    conn.destroy();
                    if (err) reject(err); else resolve(value);
                };
                const timer = setTimeout(() => finish(new PodError(`launcher ${op} timed out`)), timeoutMs);
                conn.setEncoding('utf8');
                conn.on('data', (d) => {
                    // Only the new chunk is searched: a screen reply is megabytes on one line.
                    const at = d.indexOf('\n');
                    const nl = at < 0 ? -1 : buf.length + at;
                    buf += d;
                    if (nl < 0) return;
                    let res;
                    try { res = JSON.parse(buf.slice(0, nl)); } catch { return finish(new PodError(`launcher ${op}: bad reply`)); }
                    if (!res.ok) return finish(new PodError(`launcher ${op}: ${res.error}`));
                    finish(null, res.result);
                });
                conn.on('error', (err) => finish(new PodError(`launcher unreachable: ${err.code || err.message}`)));
                conn.on('close', () => finish(new PodError(`launcher ${op}: connection closed`)));
                conn.write(JSON.stringify({ id, op, ...args }) + '\n');
            });
        },
    };
}

// ── Per-pod controller client ─────────────────────────────────────────────
// The bridge's auto-browser client (share, frames, getSession, ...) pointed at one pod, plus the
// calls the pod lifecycle needs. Nothing returned carries the token or the noVNC password.
export function createPodClient({ baseUrl, token, fetchImpl = fetch, timeoutMs = 20_000 }) {
    const base = baseUrl.replace(/\/+$/, '');
    const headers = { Authorization: `Bearer ${token}` };
    async function call(method, path, body, t = timeoutMs) {
        let res;
        try {
            res = await fetchImpl(base + path, {
                method,
                headers: body === undefined ? headers : { ...headers, 'Content-Type': 'application/json' },
                body: body === undefined ? undefined : JSON.stringify(body),
                signal: AbortSignal.timeout(t),
            });
        } catch (err) {
            throw new PodError(`pod controller unreachable: ${err.cause?.code || err.name}`, 502, 'unreachable');
        }
        if (!res.ok) {
            let detail = '';
            try { detail = (await res.text()).slice(0, 200); } catch {}
            throw new PodError(`pod ${method} ${path.split('/').slice(0, 2).join('/')} -> ${res.status} ${detail}`, res.status);
        }
        return res.json();
    }
    return {
        ...createAutoBrowserClient({ baseUrl, token, fetchImpl, timeoutMs }),
        async readyz({ timeoutMs: t = 2000 } = {}) {
            try {
                const res = await fetchImpl(base + '/readyz', { headers, signal: AbortSignal.timeout(t) });
                await res.arrayBuffer().catch(() => {});
                return res.ok;
            } catch { return false; }
        },
        // The reply's takeover URL carries the noVNC password, so only id and status come back.
        async createSession({ authProfile, startUrl } = {}) {
            const body = {};
            if (authProfile) body.auth_profile = authProfile;
            if (startUrl) body.start_url = startUrl;
            const s = await call('POST', '/sessions', body, 60_000);
            return { id: s.id, status: s.status ?? null };
        },
        closeSession: (sid) => call('DELETE', `/sessions/${encodeURIComponent(sid)}`).then(() => true),
        saveAuthProfile: (sid, name) =>
            call('POST', `/sessions/${encodeURIComponent(sid)}/auth-profiles`, { profile_name: name }).then(() => true),
        listTabs: (sid) => call('GET', `/sessions/${encodeURIComponent(sid)}/tabs`),
        // How many of the session's approvals still wait for a decision (none on an error).
        async pendingApprovals(sid) {
            const list = await call('GET', `/approvals?status=pending&session_id=${encodeURIComponent(sid)}`, undefined, 5000);
            return Array.isArray(list) ? list.filter((a) => !a?.status || a.status === 'pending').length : 0;
        },
    };
}

/** True when something answers on 127.0.0.1:port (so a pod must not be started on it). */
export function portInUse(port, { timeoutMs = 300 } = {}) {
    return new Promise((resolve) => {
        const s = connect({ host: '127.0.0.1', port });
        const end = (v) => { s.destroy(); resolve(v); };
        s.setTimeout(timeoutMs, () => end(false));
        s.on('connect', () => end(true));
        s.on('error', () => end(false));
    });
}

async function httpOk(url, timeoutMs = 1500) {
    try {
        const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
        await res.arrayBuffer().catch(() => {});
        return res.ok;
    } catch { return false; }
}

const VNC_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
export function newVncPassword() {
    // 8 chars is the VNC protocol's limit; rejection sampling keeps them uniform.
    let out = '';
    while (out.length < 8) for (const b of randomBytes(16)) if (b < 248 && out.length < 8) out += VNC_ALPHABET[b % 62];
    return out;
}

function loadJson(path) {
    if (!path) return null;
    try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}
function saveJson(path, value) {
    if (!path) return;
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    const tmp = `${path}.tmp`;
    writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 });
    renameSync(tmp, path);
}

export function createPodManager({
    launcher,                       // {call(op, args)}
    clientFor,                      // ({apiPort}) => pod client (createPodClient)
    store = null,                   // LinkStore: a chat's link (forChat) and whether it is held
    maxPods = 8,
    warm = 1,
    idleMs = 60 * 60_000,
    protectMaxMs = 12 * 3600_000,   // no protection (approval, hold) outlives this much inactivity
    healthMs = 10_000,
    authEveryMs = 60_000,
    readyTimeoutMs = 30_000,
    readyPollMs = 150,
    evictMinIdleMs = 60_000,        // a pod used this recently counts as busy, not evictable
    podsPath = null,                // pods.json
    chatsPath = null,               // chats.json
    nodeReady = (ports) => httpOk(`http://127.0.0.1:${ports.novnc}/vnc.html`),
    portBusy = portInUse,
    portBases = null,               // {novnc, api, playwright}: slot n uses base + n
    now = Date.now,
    log = () => {},
    newId = () => randomBytes(16).toString('hex'),
    newPassword = newVncPassword,
    sessionCheckMs = 2000,          // ensure({check}): a session seen alive this recently is not asked again
    recoverLimit = 2,               // at most this many recoveries of a dead browser per chat ...
    recoverWindowMs = 5 * 60_000,   // ... in this window
    startTimeoutMs = 90_000,        // a chat's start that takes longer is torn down and the chat left asleep
    sessionFreshMs = 150_000,       // live: the session answered this recently (the sweep asks every minute)
    sweepMs = 60_000,               // phantomSweep: running chats whose pod or session is gone
} = {}) {
    warm = Math.max(0, Math.min(2, warm, maxPods));
    const pods = new Map();         // slot -> pod
    const chats = new Map();        // chatKey -> chat
    const pending = new Map();      // chatKey -> Promise (one ensure at a time per chat)
    const stopping = new Map();     // chatKey -> Promise
    const failures = new Map();     // slot -> consecutive health failures
    const blocked = new Set();      // slots whose ports something else holds
    const timings = [];             // the last starts, for /api/pods and the bench
    const holds = new Map();        // chatKey -> Map(token -> why): kept from the idle stop and eviction
    let refilling = null;
    let timers = [];
    let closed = false;

    for (const c of loadJson(chatsPath)?.chats || []) {
        if (!CHAT_KEY.test(c.chatKey)) continue;
        // A pod is only "running" once reconcile has seen it; until then the chat is asleep.
        chats.set(c.chatKey, { ...c, state: c.state === 'none' || c.state === 'crashed' ? c.state : 'asleep' });
    }
    const savedPods = loadJson(podsPath)?.pods || [];

    function persist() {
        saveJson(chatsPath, { chats: [...chats.values()].map(({ chatKey, source, linkId, slot, podId, sessionId, state, lastAgentAt, lastViewerAt, hasAuth, forkChecked, fresh }) =>
            ({ chatKey, source: source ?? null, linkId: linkId ?? null, slot: slot ?? null, podId: podId ?? null, sessionId: sessionId ?? null, state, lastAgentAt: lastAgentAt ?? 0, lastViewerAt: lastViewerAt ?? 0, hasAuth: !!hasAuth, forkChecked: !!forkChecked, fresh: !!fresh })) });
        saveJson(podsPath, { pods: [...pods.values()].map(({ slot, podId, vncPassword, ports, state, chatKey }) =>
            ({ slot, podId, vncPassword, ports, state, chatKey: chatKey ?? null, sessionId: chatKey ? chats.get(chatKey)?.sessionId ?? null : null })) });
    }

    const linkOf = (chatKey) => store?.findChat?.(chatKey) ?? null;
    const held = (chatKey) => HELD.has(linkOf(chatKey)?.status);
    const lastActive = (chat) => Math.max(chat?.lastAgentAt || 0, chat?.lastViewerAt || 0);
    // Why this chat's pod must not be stopped for being idle or evicted, or null. Held links
    // always protect (they are released on their own when the viewer leaves); a hold or a
    // pending approval only until protectMaxMs passes with no activity at all.
    async function protectedBy(chat) {
        if (held(chat.chatKey)) return 'held';
        if (now() - lastActive(chat) >= protectMaxMs) return null;
        const h = holds.get(chat.chatKey);
        if (h && h.size) return [...h.values()][0];
        const pod = chat.slot !== null ? pods.get(chat.slot) : null;
        if (pod?.client?.pendingApprovals && chat.sessionId && pod.podId === chat.podId) {
            try { if (await pod.client.pendingApprovals(chat.sessionId) > 0) return 'approval_pending'; }
            catch { /* a controller that does not answer is the health check's business */ }
        }
        return null;
    }
    /** Keeps a chat's pod from the idle stop and eviction until the returned release() runs. */
    function hold(chatKey, why = 'hold') {
        if (!CHAT_KEY.test(chatKey || '')) throw new PodError('bad chat_key', 400, 'bad_request');
        const token = Symbol(why);
        if (!holds.has(chatKey)) holds.set(chatKey, new Map());
        holds.get(chatKey).set(token, String(why));
        let done = false;
        return () => {
            if (done) return;
            done = true;
            const h = holds.get(chatKey);
            h?.delete(token);
            if (h && !h.size) holds.delete(chatKey);
            // Released: the idle clock starts from now, not from before the hold.
            const chat = chats.get(chatKey);
            if (chat) chat.lastAgentAt = Math.max(chat.lastAgentAt || 0, now());
        };
    }
    const warmPods = () => [...pods.values()].filter((p) => !p.chatKey && (p.state === 'ready' || p.state === 'starting'));
    const freeSlot = () => {
        for (let s = 0; s < maxPods; s++) if (!pods.has(s) && !blocked.has(s)) return s;
        return null;
    };

    function chatOf(chatKey, source) {
        let chat = chats.get(chatKey);
        if (!chat) {
            chat = { chatKey, source: source ?? null, linkId: null, slot: null, podId: null, sessionId: null, state: 'none', lastAgentAt: 0, lastViewerAt: 0, hasAuth: false };
            chats.set(chatKey, chat);
        }
        return chat;
    }

    // ── Starting a pod ────────────────────────────────────────────────────
    async function waitReady(pod) {
        const t0 = now();
        const deadline = t0 + readyTimeoutMs;
        let node = null, ctl = null;
        while (now() < deadline && !closed) {
            if (node === null && await nodeReady(pod.ports)) node = now() - t0;
            if (ctl === null && await pod.client.readyz()) ctl = now() - t0;
            if (node !== null && ctl !== null) return { node_ready_ms: node, ctl_ready_ms: ctl };
            await sleep(readyPollMs);
        }
        throw new PodError(`browser pod in slot ${pod.slot} was not ready after ${Math.round(readyTimeoutMs / 1000)} s`);
    }

    // Starts a pod in `slot` and resolves once it is ready. On failure the slot is freed again.
    function startPod(slot) {
        const pod = { slot, podId: newId(), vncPassword: newPassword(), ports: null, state: 'starting', chatKey: null, client: null, startedAt: now(), timings: {} };
        // Registered at once, so a chat arriving meanwhile sees this pod as a spare on its way.
        pods.set(slot, pod);
        pod.ready = (async () => {
            const t0 = now();
            // Something else answering on one of the slot's ports: leave the slot alone.
            const ps = portsOf(slot);
            if (ps && (await Promise.all([ps.novnc, ps.api, ps.playwright].map((p) => portBusy(p)))).some(Boolean)) {
                blocked.add(slot);
                if (pods.get(slot) === pod) pods.delete(slot);
                log(`pod slot ${slot}: a port is already in use on 127.0.0.1; skipping the slot`);
                throw new PodError(`slot ${slot} ports are in use`, 503, 'port_busy');
            }
            try {
                const r = await launcher.call('ensure', { slot, pod_id: pod.podId, vnc_password: pod.vncPassword });
                pod.ports = r.ports;
                learnBases(slot, r.ports);
                pod.client = clientFor({ apiPort: r.ports.api, slot });
                pod.timings.created_ms = now() - t0;
                const ready = await waitReady(pod);
                pod.timings.node_ready_ms = pod.timings.created_ms + ready.node_ready_ms;
                pod.timings.ctl_ready_ms = pod.timings.created_ms + ready.ctl_ready_ms;
                if (pod.state === 'starting') pod.state = pod.chatKey ? 'assigned' : 'ready';
                persist();
                return pod;
            } catch (err) {
                log(`pod slot ${slot}: start failed: ${short(err)}`);
                if (pods.get(slot) === pod) pods.delete(slot);
                await launcher.call('stop', { slot }).catch(() => {});
                persist();
                throw err;
            }
        })();
        pod.ready.catch(() => {});
        return pod;
    }

    // Starts a pod in the first free slot, or returns null when none is free.
    function claimSlot() {
        const slot = freeSlot();
        return slot === null ? null : startPod(slot);
    }
    // A slot's ports are base + slot; the bases come from config or the launcher's first reply.
    let bases = portBases;
    function learnBases(slot, ports) {
        if (ports && !bases) bases = { novnc: ports.novnc - slot, api: ports.api - slot, playwright: ports.playwright - slot };
    }
    const portsOf = (slot) => (bases ? { novnc: bases.novnc + slot, api: bases.api + slot, playwright: bases.playwright + slot } : null);

    function refill() {
        if (refilling || closed) return refilling;
        refilling = (async () => {
            // Yield first: with nothing to do the body would otherwise finish (and clear
            // `refilling`) before the assignment, leaving a settled promise that blocks every refill.
            await null;
            try {
                while (!closed && warmPods().length < warm && pods.size < maxPods) {
                    const pod = claimSlot();
                    if (!pod) break;
                    try { await pod.ready; } catch (err) { if (err.code !== 'port_busy') break; }
                }
            } finally { refilling = null; }
        })();
        return refilling;
    }

    // A pod for a chat: a ready spare, a spare about to be ready, a cold start, or an evicted slot.
    async function acquire(forKey) {
        for (let tries = 0; tries <= maxPods; tries++) {
            const spares = warmPods();
            const spare = spares.find((p) => p.state === 'ready') || spares[0];
            const pod = spare || claimSlot() || (await evict(forKey));
            const warmAtClaim = !!spare && spare.state === 'ready';
            pod.chatKey = forKey;
            try {
                await pod.ready;
            } catch (err) {
                // That pod died while starting, or its ports were taken: try the next one.
                if (err.code === 'port_busy' || spare) continue;
                throw err;
            }
            pod.state = 'assigned';
            return { pod, warm: warmAtClaim, spare: !!spare };
        }
        throw new PodError('no browser pod could be started', 503);
    }

    async function evict(forKey) {
        const t = now();
        const candidates = [...pods.values()]
            .filter((p) => p.state === 'assigned' && p.chatKey && p.chatKey !== forKey && !held(p.chatKey) && !pending.has(p.chatKey) && !stopping.has(p.chatKey))
            .map((p) => ({ p, at: lastActive(chats.get(p.chatKey)) }))
            .filter(({ at }) => t - at >= evictMinIdleMs)
            .sort((a, b) => a.at - b.at);
        // Longest idle first, skipping any pod that is protected (approval pending, a hold).
        let victim = null;
        for (const c of candidates) {
            const chat = chats.get(c.p.chatKey);
            if (chat && !(await protectedBy(chat))) { victim = c; break; }
        }
        if (!victim) throw new PodError(`all ${maxPods} browsers are busy; try again when one is free`, 503, 'busy');
        const { p } = victim;
        log(`pod slot ${p.slot}: evicting the least recently used chat to make room`);
        await stopChat(p.chatKey, 'evicted');
        return claimSlot() || warmPods()[0] || (() => { throw new PodError(`all ${maxPods} browsers are busy; try again when one is free`, 503, 'busy'); })();
    }

    // ── Public: a chat's pod ──────────────────────────────────────────────
    function describe(chat) {
        const pod = chat.slot !== null ? pods.get(chat.slot) : null;
        const link = linkOf(chat.chatKey);
        return {
            chat_key: chat.chatKey,
            state: chat.state,
            session_id: chat.sessionId,
            link_id: link?.id ?? chat.linkId ?? null,
            slot: pod?.slot ?? null,
            api_url: pod?.ports ? `http://127.0.0.1:${pod.ports.api}` : null,
            mcp_url: pod?.ports ? `http://127.0.0.1:${pod.ports.api}/mcp` : null,
            novnc_port: pod?.ports?.novnc ?? null,
        };
    }

    /**
     * Ensures the chat has a running pod and session and counts as agent activity.
     * {verify: true} first checks the pod still answers (the MCP server's retry after a refused
     * connection) and replaces it when it does not. {forkedFrom}: the parent chat's key, for a
     * forked or side chat (see inheritLogin).
     */
    const DEAD_SESSION = new Set(['closed', 'interrupted', 'failed', 'ended']);
    // ensure({check}): is the running chat's session alive? null when it is, else why not.
    async function sessionDead(chat, pod) {
        if (chat.checkedAt && now() - chat.checkedAt < sessionCheckMs) return null;
        try {
            const s = await pod.client.getSession(chat.sessionId);
            if (s && DEAD_SESSION.has(String(s.status))) return 'session_ended';
            chat.checkedAt = now();
            return null;
        } catch (err) {
            if (err.status === 404) return 'session_ended';
            return (await pod.client.readyz()) ? null : 'pod_crashed';
        }
    }
    // The URL a recovered or woken browser opens again: the link's last page, http(s) only.
    const resumeUrlOf = (chatKey) => {
        const u = linkOf(chatKey)?.url;
        return typeof u === 'string' && /^https?:\/\//i.test(u) ? u : null;
    };

    /**
     * {check: true} (the MCP server's preflight before a browser call): the running chat's
     * session must still answer, else the browser is recovered. A woken or recovered browser
     * reopens the link's last page, and the answer carries recovered: {reason, previous_session_id}.
     * A dead browser is recovered at most recoverLimit times per recoverWindowMs.
     */
    async function ensure(chatKey, { source = null, verify = false, forkedFrom = null, check = false } = {}) {
        if (!CHAT_KEY.test(chatKey || '')) throw new PodError('bad chat_key', 400, 'bad_request');
        if (forkedFrom !== null && (typeof forkedFrom !== 'string' || !CHAT_KEY.test(forkedFrom) || forkedFrom === chatKey)) {
            throw new PodError('bad forked_from', 400, 'bad_request');
        }
        if (closed) throw new PodError('bridge is shutting down');
        const chat = chatOf(chatKey, source);
        chat.lastAgentAt = now();
        if (stopping.has(chatKey)) await stopping.get(chatKey).catch(() => {});
        if (pending.has(chatKey)) return pending.get(chatKey);
        const pod = chat.slot !== null ? pods.get(chat.slot) : null;
        let recovery = null;
        if (chat.state === 'running' && pod && pod.podId === chat.podId && pod.state === 'assigned') {
            if (check) {
                const dead = await sessionDead(chat, pod);
                if (!dead) return describe(chat);
                recovery = dead;
            } else if (!verify || await pod.client.readyz()) return describe(chat);
            else recovery = 'pod_crashed';
            if (check) {
                const recent = (chat.recoveries || []).filter((t) => now() - t < recoverWindowMs);
                if (recent.length >= recoverLimit) {
                    throw new PodError(`this chat's browser died ${recent.length} times in ${Math.round(recoverWindowMs / 60_000)} minutes; not restarting it again yet`, 503, 'recovery_limit');
                }
                chat.recoveries = [...recent, now()];
            }
            log(`pod slot ${pod.slot}: chat ${chatKey.slice(0, 8)} ${recovery === 'session_ended' ? 'session ended' : 'not answering'}; replacing it`);
            await stopChat(chatKey, 'crashed');
        } else if (check && chat.sessionId && chat.state !== 'starting') {
            recovery = chat.state === 'crashed' || chat.state === 'running' ? 'pod_crashed' : 'pod_asleep';
        }
        const previous = chat.sessionId;
        // Ended by the user (stopChat 'user_ended'): the login is kept, the last page is not.
        const fresh = !!chat.fresh;
        const resumeUrl = previous && !fresh ? resumeUrlOf(chatKey) : null;
        if (check && fresh && recovery) recovery = 'ended';
        const gen = (chat.startGen || 0) + 1;
        chat.startGen = gen;
        chat.startedAt = now();
        // A start abandoned by its deadline (abandonStart) must not touch the chat or a slot
        // someone else has by now.
        const stale = () => chat.startGen !== gen;
        const dropPod = async (pod) => {
            if (pods.get(pod.slot) !== pod) return;
            pods.delete(pod.slot);
            await launcher.call('stop', { slot: pod.slot }).catch(() => {});
        };
        const p = (async () => {
            const t0 = now();
            chat.state = 'starting';
            if (forkedFrom && !chat.hasAuth && !chat.forkChecked) await inheritLogin(chat, forkedFrom);
            let got;
            try {
                got = await acquire(chatKey);
            } catch (err) {
                if (!stale()) chat.state = chat.sessionId ? 'asleep' : 'none';
                throw err;
            }
            const { pod: mine, warm: wasWarm, spare: fromSpare } = got;
            try {
                if (stale()) throw new PodError('start abandoned', 503, 'start_timeout');
                let adopted = false;
                if (chat.hasAuth) {
                    try { adopted = !!(await launcher.call('adopt_auth', { slot: mine.slot, chat_hash: chatKey })).adopted; }
                    catch (err) { log(`pod slot ${mine.slot}: restoring the login failed: ${short(err)}`); }
                }
                const s0 = now();
                let session;
                try {
                    session = await mine.client.createSession({ ...(adopted ? { authProfile: AUTH_PROFILE } : {}), ...(resumeUrl ? { startUrl: resumeUrl } : {}) });
                } catch (err) {
                    if (!adopted && !resumeUrl) throw err;
                    log(`pod slot ${mine.slot}: session with the saved login or last page failed (${short(err)}); starting without them`);
                    session = await mine.client.createSession({});
                }
                const sessionMs = now() - s0;
                if (stale()) throw new PodError('start abandoned', 503, 'start_timeout');
                Object.assign(chat, { slot: mine.slot, podId: mine.podId, sessionId: session.id, state: 'running', lastAgentAt: now(), checkedAt: now(), fresh: false });
                const link = store?.forChat?.(chatKey, session.id);
                if (link) chat.linkId = link.id;
                // A fresh start's link forgets the page it was ended on.
                if (link && fresh) store.update?.(link, { url: null, title: null });
                const timing = { warm: wasWarm, spare: fromSpare, total_ms: now() - t0, session_ms: sessionMs, ...(wasWarm ? {} : mine.timings), at: now() };
                timings.push(timing);
                if (timings.length > 50) timings.shift();
                log(`pod slot ${mine.slot}: chat ${chatKey.slice(0, 8)} ${wasWarm ? 'warm' : fromSpare ? 'spare (still starting)' : 'cold'} start ${timing.total_ms} ms`);
                persist();
                return describe(chat);
            } catch (err) {
                if (stale()) { await dropPod(mine); persist(); throw err; }
                log(`pod slot ${mine.slot}: starting the session failed: ${short(err)}`);
                chat.state = chat.sessionId ? 'asleep' : 'none';
                await dropPod(mine);
                persist();
                throw err instanceof PodError ? err : new PodError(short(err));
            } finally {
                refill();
            }
        })();
        let timer;
        const deadline = new Promise((_, reject) => {
            timer = setTimeout(() => {
                abandonStart(chatKey, gen).finally(() => reject(new PodError(`the browser did not start within ${Math.round(startTimeoutMs / 1000)} s; it is asleep and starts again on the next call`, 503, 'start_timeout')));
            }, startTimeoutMs);
            timer.unref?.();
        });
        const timed = Promise.race([p, deadline]).finally(() => clearTimeout(timer));
        p.catch(() => {});
        timed.catch(() => {});
        pending.set(chatKey, timed);
        let d;
        try { d = await timed; } finally { if (pending.get(chatKey) === timed) pending.delete(chatKey); }
        return recovery && check ? { ...d, recovered: { reason: recovery, previous_session_id: previous } } : d;
    }

    // A start past startTimeoutMs: the pod it was getting is stopped (its login stashed first when
    // the chat has none saved yet; a saved one is kept as it is), and the chat is left asleep,
    // so the next call or wake starts it again from the saved login and the link's last page.
    async function abandonStart(chatKey, gen) {
        const chat = chats.get(chatKey);
        if (!chat || chat.startGen !== gen) return;
        chat.startGen = gen + 1;
        for (const pod of [...pods.values()].filter((x) => x.chatKey === chatKey)) {
            if (!chat.hasAuth) {
                try { if ((await launcher.call('stash_auth', { slot: pod.slot, chat_hash: chatKey }))?.stashed) chat.hasAuth = true; }
                catch (err) { log(`pod slot ${pod.slot}: keeping the login failed: ${short(err)}`); }
            }
            if (pods.get(pod.slot) === pod) pods.delete(pod.slot);
            await launcher.call('stop', { slot: pod.slot }).catch((err) => log(`pod slot ${pod.slot}: stopping failed: ${short(err)}`));
        }
        Object.assign(chat, { state: 'asleep', slot: null, podId: null });
        log(`chat ${chatKey.slice(0, 8)}: start took over ${Math.round(startTimeoutMs / 1000)} s; torn down, asleep`);
        persist();
        refill();
    }

    /**
     * Is a browser up for this chat? {live, pod, reason}. live only while its pod runs and its
     * session answered in the last sessionFreshMs, or while it starts (for under startTimeoutMs).
     * pod: running | starting | asleep | dead | none.
     */
    function liveness(chatKey) {
        const chat = chats.get(chatKey);
        if (!chat || (chat.state === 'none' && !pending.has(chatKey))) return { live: false, pod: 'none', reason: 'no_browser' };
        if (pending.has(chatKey) || chat.state === 'starting') {
            return now() - (chat.startedAt || 0) < startTimeoutMs ? { live: true, pod: 'starting', reason: null } : { live: false, pod: 'dead', reason: 'start_stuck' };
        }
        if (chat.state === 'running') {
            const pod = chat.slot !== null ? pods.get(chat.slot) : null;
            if (!pod || pod.podId !== chat.podId || pod.state !== 'assigned') return { live: false, pod: 'dead', reason: 'pod_gone' };
            if (!chat.checkedAt || now() - chat.checkedAt > sessionFreshMs) return { live: false, pod: 'dead', reason: 'session_not_answering' };
            return { live: true, pod: 'running', reason: null };
        }
        if (chat.state === 'crashed') return { live: false, pod: 'dead', reason: 'crashed' };
        return { live: false, pod: 'asleep', reason: 'asleep' };
    }
    // The session answered (a frame, an observe): it counts as alive for sessionFreshMs.
    function sessionSeen(chatKey) {
        const chat = chats.get(chatKey);
        if (chat && chat.state === 'running') chat.checkedAt = now();
    }

    /**
     * At start and every sweepMs: a chat that claims to run while its pod or session is gone is
     * put to sleep (stopChat saves its login when the pod still answers; else the last saved one
     * stays), a start the bridge is not doing is asleep, and a sleeping chat's slot is cleared.
     * Returns how many it fixed.
     */
    async function phantomSweep() {
        let fixed = 0;
        for (const chat of [...chats.values()]) {
            const key = chat.chatKey;
            if (pending.has(key) || stopping.has(key)) continue;
            const pod = chat.slot !== null ? pods.get(chat.slot) : null;
            const ours = !!pod && pod.podId === chat.podId && pod.chatKey === key;
            if (chat.state === 'running') {
                if (!ours || pod.state !== 'assigned') {
                    Object.assign(chat, { state: 'asleep', slot: null, podId: null });
                    log(`sweep: chat ${key.slice(0, 8)} said running with no pod; asleep`);
                    fixed++;
                    continue;
                }
                let dead = null;
                try {
                    const s = await pod.client.getSession(chat.sessionId);
                    if (s && DEAD_SESSION.has(String(s.status))) dead = 'session_ended';
                } catch (err) {
                    dead = err.status === 404 ? 'session_ended' : ((await pod.client.readyz().catch(() => false)) ? null : 'pod_crashed');
                }
                if (!dead) { chat.checkedAt = now(); continue; }
                log(`sweep: chat ${key.slice(0, 8)} ${dead === 'session_ended' ? 'session ended' : 'pod not answering'}; putting it to sleep`);
                await stopChat(key, dead === 'pod_crashed' ? 'crashed' : 'session_ended');
                fixed++;
            } else if (chat.state === 'starting') {
                Object.assign(chat, { state: 'asleep', slot: null, podId: null });
                fixed++;
            } else if (chat.slot !== null || chat.podId !== null) {
                chat.slot = null;
                chat.podId = null;
                fixed++;
            }
        }
        if (fixed) persist();
        return fixed;
    }

    // A forked chat's first login is its parent's, as of now: the parent's pod (if it runs) is
    // saved first, then the launcher copies the parent's saved login to this chat, never over
    // one it already has. Logged with the short keys and the outcome only.
    async function inheritLogin(chat, parentKey) {
        const tag = `fork login: chat ${chat.chatKey.slice(0, 8)} from ${parentKey.slice(0, 8)}`;
        try {
            const saved = await checkpointAuth(parentKey, { force: true });
            const r = await launcher.call('copy_auth', { from_chat_hash: parentKey, chat_hash: chat.chatKey });
            if (r?.copied) chat.hasAuth = true;
            chat.forkChecked = true;
            persist();
            log(`${tag}: ${r?.copied ? 'copied' : `not copied (${r?.reason || 'unknown'})`}${saved ? ', parent saved first' : ''}`);
        } catch (err) {
            // Not marked as tried: the next start tries again. The chat starts without a login.
            log(`${tag}: copy failed: ${short(err)}`);
        }
    }

    // ── Stopping ──────────────────────────────────────────────────────────
    // Save -> stash -> close -> stop. Each step's failure is logged and the next still runs, so a
    // pod always goes away. `crashed` skips the save (the controller is not answering).
    function stopChat(chatKey, why = 'idle') {
        if (stopping.has(chatKey)) return stopping.get(chatKey);
        const chat = chats.get(chatKey);
        // Only the user's End starts the next browser on a new page; any other stop of a running
        // browser (idle, sleep, the agent's close, a crash) resumes on the last one. With no
        // browser running nothing has opened since, so an earlier End still stands.
        const pod = chat && chat.slot !== null ? pods.get(chat.slot) : null;
        if (!chat || !pod || pod.podId !== chat.podId) {
            if (chat && why === 'user_ended') chat.fresh = true;
            if (chat && chat.state === 'running') chat.state = why === 'crashed' ? 'crashed' : 'asleep';
            // No pod of its own: a slot it still names is someone else's or gone.
            if (chat && chat.state !== 'running' && chat.slot !== null) { chat.slot = null; chat.podId = null; }
            if (chat) persist();
            return Promise.resolve(false);
        }
        chat.fresh = why === 'user_ended';
        const p = (async () => {
            pod.state = 'stopping';
            const sid = chat.sessionId;
            if (why !== 'crashed' && sid && pod.client) {
                try { await pod.client.saveAuthProfile(sid, AUTH_PROFILE); }
                catch (err) { log(`pod slot ${pod.slot}: saving the login failed: ${short(err)}`); }
            }
            try {
                const r = await launcher.call('stash_auth', { slot: pod.slot, chat_hash: chatKey });
                if (r?.stashed) chat.hasAuth = true;
            } catch (err) { log(`pod slot ${pod.slot}: keeping the login failed: ${short(err)}`); }
            if (why !== 'crashed' && sid && pod.client) {
                try { await pod.client.closeSession(sid); }
                catch (err) { if (err.status !== 404) log(`pod slot ${pod.slot}: closing the session failed: ${short(err)}`); }
            }
            try { await launcher.call('stop', { slot: pod.slot }); }
            catch (err) { log(`pod slot ${pod.slot}: stopping failed: ${short(err)}`); }
            if (pods.get(pod.slot) === pod) pods.delete(pod.slot);
            failures.delete(pod.slot);
            chat.state = why === 'crashed' ? 'crashed' : 'asleep';
            chat.slot = null;
            chat.podId = null;
            log(`pod slot ${pod.slot}: chat ${chatKey.slice(0, 8)} stopped (${why})`);
            persist();
            return true;
        })();
        stopping.set(chatKey, p);
        p.finally(() => { stopping.delete(chatKey); refill(); }).catch(() => {});
        return p;
    }

    // The login is also saved while the pod runs: after the user hands control back, and at most
    // once a minute after page-changing calls, so a crash loses little.
    const lastCheckpoint = new Map();
    async function checkpointAuth(chatKey, { force = false } = {}) {
        const chat = chats.get(chatKey);
        const pod = chat && chat.slot !== null ? pods.get(chat.slot) : null;
        if (!chat || chat.state !== 'running' || !pod || pod.state !== 'assigned' || !chat.sessionId) return false;
        if (!force && now() - (lastCheckpoint.get(chatKey) || 0) < authEveryMs) return false;
        lastCheckpoint.set(chatKey, now());
        try {
            await pod.client.saveAuthProfile(chat.sessionId, AUTH_PROFILE);
            const r = await launcher.call('stash_auth', { slot: pod.slot, chat_hash: chatKey, keep: true });
            if (r?.stashed && !chat.hasAuth) { chat.hasAuth = true; persist(); }
            return true;
        } catch (err) {
            log(`pod slot ${pod.slot}: saving the login failed: ${short(err)}`);
            return false;
        }
    }

    // ── Timers ────────────────────────────────────────────────────────────
    async function idleSweep() {
        const t = now();
        for (const chat of chats.values()) {
            if (chat.state !== 'running' || pending.has(chat.chatKey) || stopping.has(chat.chatKey)) continue;
            if (t - lastActive(chat) < idleMs) continue;
            const why = await protectedBy(chat);
            if (why) {
                if (chat.keptFor !== why) log(`pod slot ${chat.slot}: chat ${chat.chatKey.slice(0, 8)} idle but kept (${why})`);
                chat.keptFor = why;
                continue;
            }
            chat.keptFor = null;
            await stopChat(chat.chatKey, 'idle');
        }
    }

    async function healthCheck() {
        // A slot skipped for a busy port is tried again once whatever held it may have gone.
        blocked.clear();
        let listed;
        try { listed = await launcher.call('list'); }
        catch (err) { log(`pod health: launcher list failed: ${short(err)}`); return; }
        const up = new Map((listed.pods || []).map((p) => [p.slot, p]));
        for (const pod of [...pods.values()]) {
            if (pod.state !== 'assigned' && pod.state !== 'ready') continue;
            const l = up.get(pod.slot);
            const running = l && l.pod_id === pod.podId && l.containers?.node?.state === 'running' && l.containers?.controller?.state === 'running';
            const ok = running && await pod.client.readyz();
            if (ok) { failures.delete(pod.slot); continue; }
            const n = (failures.get(pod.slot) || 0) + 1;
            failures.set(pod.slot, n);
            if (n < 2) continue;
            log(`pod slot ${pod.slot}: failed two health checks; stopping it`);
            if (pod.chatKey && pod.state === 'assigned') await stopChat(pod.chatKey, 'crashed');
            else {
                pods.delete(pod.slot);
                failures.delete(pod.slot);
                await launcher.call('stop', { slot: pod.slot }).catch(() => {});
                persist();
                refill();
            }
        }
    }

    // At boot: adopt what pods.json says was assigned and is still up and ready; stop the rest.
    async function reconcile() {
        let listed;
        try { listed = await launcher.call('list'); }
        catch (err) { log(`pod reconcile: launcher list failed: ${short(err)}`); return { adopted: 0, removed: 0 }; }
        const known = new Map(savedPods.filter((p) => p.state === 'assigned' && p.chatKey).map((p) => [p.slot, p]));
        let adopted = 0, removed = 0;
        for (const l of listed.pods || []) {
            const rec = known.get(l.slot);
            const chat = rec && chats.get(rec.chatKey);
            const running = l.containers?.node?.state === 'running' && l.containers?.controller?.state === 'running';
            if (rec && chat && rec.podId === l.pod_id && running && chat.podId === l.pod_id) {
                const client = clientFor({ apiPort: l.ports.api, slot: l.slot });
                if (await client.readyz()) {
                    pods.set(l.slot, { slot: l.slot, podId: l.pod_id, vncPassword: rec.vncPassword, ports: l.ports, state: 'assigned', chatKey: rec.chatKey, client, startedAt: now(), timings: {}, ready: Promise.resolve() });
                    learnBases(l.slot, l.ports);
                    chat.state = 'running';
                    chat.slot = l.slot;
                    chat.checkedAt = now(); // answered readyz; the first sweep asks the session
                    adopted++;
                    continue;
                }
            }
            await launcher.call('stop', { slot: l.slot }).catch((err) => log(`pod reconcile: stopping slot ${l.slot} failed: ${short(err)}`));
            removed++;
        }
        for (const chat of chats.values()) if (chat.state === 'running' && !pods.has(chat.slot)) { chat.state = 'asleep'; chat.slot = null; chat.podId = null; }
        persist();
        // Loaded asleep from chats.json but still naming the slot it had: not any more.
        for (const chat of chats.values()) if (chat.state !== 'running' && chat.slot !== null) { chat.slot = null; chat.podId = null; }
        persist();
        if (adopted || removed) log(`pod reconcile: adopted ${adopted}, removed ${removed}`);
        return { adopted, removed };
    }

    async function start() {
        await reconcile();
        const fixed = await phantomSweep().catch((e) => { log(`sweep: ${short(e)}`); return 0; });
        if (fixed) log(`sweep at start: ${fixed} phantom browser(s) fixed`);
        refill();
        const every = (fn, ms) => { const t = setInterval(() => fn().catch((e) => log(`pod timer: ${short(e)}`)), ms); t.unref?.(); timers.push(t); };
        every(idleSweep, Math.min(30_000, Math.max(1000, Math.floor(idleMs / 4))));
        every(healthCheck, healthMs);
        every(async () => { const n = await phantomSweep(); if (n) log(`sweep: ${n} phantom browser(s) fixed`); }, sweepMs);
    }

    // Pods stay up across a bridge restart (reconcile adopts them); only the timers stop.
    function close() {
        closed = true;
        for (const t of timers) clearInterval(t);
        timers = [];
        persist();
    }

    // ── Lookups for the HTTP side ─────────────────────────────────────────
    function chatForLink(linkId) {
        for (const c of chats.values()) if (c.linkId === linkId) return c;
        return null;
    }
    function chatForSession(sessionId) {
        for (const c of chats.values()) if (c.sessionId === sessionId) return c;
        return null;
    }
    /** What /take and the frame path need for a chat: its pod's client and noVNC, if running. */
    function podOf(chatKey) {
        const chat = chats.get(chatKey);
        const pod = chat && chat.slot !== null ? pods.get(chat.slot) : null;
        if (!chat || chat.state !== 'running' || !pod || pod.state !== 'assigned' || pod.podId !== chat.podId) return null;
        return { slot: pod.slot, client: pod.client, novncPort: pod.ports.novnc, vncPassword: pod.vncPassword, sessionId: chat.sessionId };
    }
    /**
     * The chat's pod's whole screen as a PNG ({mime, width, height, data: base64}), captured by the
     * launcher inside that pod (op screen, which also checks the pod id). Never starts a pod.
     */
    async function screen(chatKey) {
        if (!CHAT_KEY.test(chatKey || '')) throw new PodError('bad chat_key', 400, 'bad_request');
        const p = podOf(chatKey);
        if (!p) throw new PodError('this chat\'s browser is asleep', 503, 'asleep');
        return launcher.call('screen', { slot: p.slot, pod_id: chats.get(chatKey).podId });
    }
    /** running | starting | asleep | crashed | none, for /state's `pod` field. */
    function podState(chatKey) {
        const chat = chats.get(chatKey);
        if (!chat) return 'none';
        if (pending.has(chatKey)) return 'starting';
        return chat.state;
    }
    function touchViewer(chatKey) {
        const chat = chats.get(chatKey);
        if (chat) chat.lastViewerAt = now();
    }
    /** Starts the chat's pod without waiting (the user tapped Take control on a sleeping one). */
    function wake(chatKey) {
        const chat = chats.get(chatKey);
        if (!chat) return 'none';
        if (chat.state === 'running' && podOf(chatKey)) return 'running';
        ensure(chatKey, { source: chat.source }).catch((err) => log(`waking chat ${chatKey.slice(0, 8)} failed: ${short(err)}`));
        // lastAgentAt is set by ensure; a wake is the viewer's doing, so the idle clock is fair.
        return 'starting';
    }

    function status() {
        const t = now();
        return {
            max_pods: maxPods,
            warm_target: warm,
            idle_min: idleMs / 60_000,
            protect_max_min: protectMaxMs / 60_000,
            pods: [...pods.values()].sort((a, b) => a.slot - b.slot).map((p) => {
                const chat = p.chatKey ? chats.get(p.chatKey) : null;
                return {
                    slot: p.slot,
                    state: p.state,
                    chat: p.chatKey ? p.chatKey.slice(0, 8) : null,
                    ports: p.ports,
                    held: p.chatKey ? held(p.chatKey) : false,
                    holds: p.chatKey ? [...(holds.get(p.chatKey)?.values() || [])] : [],
                    kept_for: chat?.keptFor ?? null,
                    idle_s: chat ? Math.round((t - lastActive(chat)) / 1000) : null,
                };
            }),
            chats: [...chats.values()].filter((c) => c.state !== 'none').map((c) => ({ chat: c.chatKey.slice(0, 8), state: podState(c.chatKey), slot: c.slot, has_auth: !!c.hasAuth, idle_s: Math.round((t - lastActive(c)) / 1000) })),
            blocked_slots: [...blocked].sort((a, b) => a - b),
            recent_starts: timings.slice(-10),
        };
    }

    return {
        ensure, stopChat, checkpointAuth, idleSweep, healthCheck, reconcile, refill, start, close,
        chatForLink, chatForSession, podOf, podState, touchViewer, wake, status, hold, screen,
        liveness, sessionSeen, phantomSweep,
        get timings() { return timings.slice(); },
        _pods: pods, _chats: chats,
    };
}
