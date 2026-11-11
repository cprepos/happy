// The live bridge's HTTP surface.
//
// Public, for the phone (reached only through the Happy Agent workspace proxy):
//   GET  /live/<id>            phone page: live frame, status, Take control, Release control
//   GET  /live/<id>/frame.jpg  latest frame (image/png as auto-browser captures it)
//   GET  /live/<id>/screen.png pods only: the pod's whole screen (tab strip, address bar, dialogs),
//                              captured in the pod, at most one capture a second per link. Not
//                              PII-scrubbed, as noVNC is not. 404 no_screen on the shared browser,
//                              503 asleep (does not wake it)
//   GET  /live/<id>/state      {status: watching|user|takeover|done, reason, url, title, last_action}
//                              while held (user|takeover), also editable_focused: true when the page's
//                              focus is in a field that takes typing, false when not; absent when it
//                              can't be told (asleep, a controller without the focus route). The app's
//                              native viewer brings up the keyboard from it. Only the boolean, never
//                              the field or its value
//   POST /live/<id>/take       the user takes control: watching -> user (takeover stays takeover);
//                              -> state plus novnc_url
//   POST /live/<id>/release    the user hands control back: user|takeover -> watching, waking waiters
//   POST /live/<id>/done       alias of /release, for app builds that predate it
//   POST /live/<id>/nav        {action: back|forward|reload|goto, url?} on the link's session, only
//                              while user|takeover (else 409); goto takes http(s) only (else 400).
//                              -> {ok, url, title, can_go_back, can_go_forward}, timed_out after 10 s
//   POST /live/<id>/approve    {approval_id} the user approves the action the agent is waiting on
//   POST /live/<id>/deny       {approval_id} the user denies it. Both only for the link's own pending
//                              approval (state.approval; else 409 no_pending_approval), and only its id.
//   POST /live/<id>/auto       {on: true|false} browser yolo for this link's chat: while on, an action
//                              held for approval is approved at once (note "Auto-approved (browser
//                              yolo)"), never shown or waited on. -> {auto_approve}. Kept on the link
//                              (one per chat), saved with it; turning it on also approves the
//                              approval pending right then. /state carries auto_approve (default
//                              false) and auto_approved: [{id, summary, at}], the last 5, newest first
//   POST /live/<id>/end        the user ends the browser: the session closes, the link is done
//                              (reason user_ended) and waiters wake. With pods, the login is kept
//                              and the next browser starts on a new page
//   POST /live/<id>/sleep      pods only: the user puts the browser to sleep: the login is saved,
//                              the pod stops (pod: asleep) and a held link is released (reason
//                              user_slept, waking waiters). The link stays watching, so the next
//                              agent call or /take wakes it on its last page. 409 pods_disabled
//                              without pods, 409 <reason> on a done link; asleep already: no change
//   GET  /live/chat/<chat_key> which link belongs to this chat: {id, url, live, pod, ...state};
//                              404 when the chat has none. chat_key is sha256("happy:" + the Happy
//                              session id), first 32 hex chars. The source of truth for whether
//                              a chat shows a live browser.
//   GET  /live/<id>/vnc/<file> noVNC's files, from the link's own pod (or the shared noVNC)
//   GET  /live/<id>/vnc/websockify  (Upgrade: websocket) the VNC socket, while the link is held
// Unknown id -> 404, expired id -> 410.
//
// Private, for the MCP server (Authorization: Bearer <bridge-token>):
//   POST /api/links     {session_id}                -> {id, url, status}
//   POST /api/takeover  {session_id, reason}        -> {id, url, status}
//   POST /api/wait      {id, wait_s}                -> state, once status leaves takeover/user or wait_s passes
//   POST /api/release   {id, reason}                -> state; a takeover nobody finished goes back to watching
//   POST /api/state     {session_id?, action?}      -> the session's link state ({status: null} without one);
//                       with no session_id, a held link if any. With an action ({kind, target}) on a link
//                       nobody holds, records it as last_action.
//   POST /api/approval  {session_id|chat_key, approval_id}
//                       -> {id, url, approval}: an auto-browser approval of this link's own session,
//                       still pending, is shown to the user (state.approval, scrubbed) until decided.
//                       With browser yolo on for the link, approved at once instead:
//                       -> {id, url, approval: null, auto_approved: true, approval_status: approved}
//   POST /api/approval/wait {id, approval_id, wait_s}
//                       -> {approval_status: pending|approved|denied|gone, ...state}, once decided or wait_s passes
//   /api/links, /api/takeover and /api/state also take {chat_key} instead of session_id.
//
// With per-chat pods (config.pods, lib/pods.mjs), also:
//   POST /api/pod       {chat_key, source?, verify?} or {session_id}
//                       -> {mcp_url, session_id, link_id, url, slot}: the chat's pod, started or woken
//   POST /api/pod/close {chat_key}                  -> saves the login, closes the session, stops the pod
//   POST /api/screen    {chat_key, activate?, label?, redact?, view?} -> {mime, width, height, data
//                       (base64 PNG), session_id, url, title, captured_at, tz, view, screenshot_path,
//                       screenshot_url, pii_scrubbed, redaction, evidence_bar_px, panel_px,
//                       capture_rect, raw_sha256, filed_sha256, chrome_strip, address_bar_scheme?,
//                       screenshot_pii_scrub?}: that chat's pod's screen (browser_screenshot scope
//                       "screen") with its session's tab brought to the front (activate false: it
//                       must already be); view "desktop" the whole screen with the desktop panel and
//                       its clock, "tab" the browser window's rectangle alone (absent: the
//                       deployment's SCREENSHOT_TIME_MODE). OCR-scrubbed by the pod's controller
//                       except the browser's own address bar strip and the panel (redact false, only
//                       when sent as false: not at all) and filed as the session's artifact; nothing
//                       is drawn on it. 400 bad view; 503 asleep (never wakes it)
//   POST /api/page-shot {chat_key, label?, redact?} -> the same fields: that chat's session's page
//                       (viewport), for browser_screenshot scope "page" with redact false
//   POST /api/tools     {}                          -> {tools}: auto-browser's tool list, cached, so
//                       listing tools never starts a pod
//   GET  /api/pods                                  -> slots, chats, recent start timings
// A link then belongs to a chat (one link per chat, across pod restarts). While its pod is asleep,
// frame.jpg answers 503 {error: asleep} and does not wake it, /state carries pod: asleep, and
// /take wakes it (202, pod: starting; ask again).
//
// Statuses: watching (the agent drives), user (the user took control on their own; the agent's
// actions are refused), takeover (the agent asked for the user and waits), done (session closed,
// or reason user_ended: the user ended it from the app).
import { timingSafeEqual, randomBytes, createHash } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { connect as netConnect } from 'node:net';
import { renderPage, renderGone } from './page.mjs';
import { APPROVAL_ID, approvalSummary } from './approval.mjs';

const LIVE_ROUTE = /^\/live\/([^/]+)(\/frame\.jpg|\/screen\.png|\/state|\/done|\/take|\/release|\/end|\/sleep|\/nav|\/approve|\/deny|\/auto)?\/?$/;
const CHAT_ROUTE = /^\/live\/chat\/([0-9a-f]{32})\/?$/;
const CHAT_KEY = /^[0-9a-f]{32}$/;
// noVNC through the bridge. Matched on the raw request path, before any URL normalising, so
// `..`, `%2e` and the like never reach a pattern that would accept them: every segment starts
// with a letter, digit, `_` or `-`, and `%`, `\` and empty segments are not in the charset.
const VNC_PREFIX = /^\/live\/[^/]*\/vnc(?:\/|$)/;
const VNC_FILE = /^\/live\/([0-9a-f]{32})\/vnc\/((?:[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}\/){0,7}[A-Za-z0-9_-][A-Za-z0-9._-]{0,127})$/;
const VNC_SOCKET = /^\/live\/([0-9a-f]{32})\/vnc\/websockify$/;
const WS_KEY = /^[A-Za-z0-9+/]{22}==$/;
const WS_PROTOCOL = /^[A-Za-z0-9 ,._-]{1,200}$/;
// Only these headers cross the static proxy, either way: no cookies, no auth, no Location.
const VNC_REQ_HEADERS = ['accept', 'accept-encoding', 'accept-language', 'if-none-match', 'if-modified-since', 'user-agent'];
const VNC_RES_HEADERS = ['content-type', 'content-length', 'content-encoding', 'etag', 'last-modified'];
const WS_RES_HEADERS = new Set(['upgrade', 'connection', 'sec-websocket-accept', 'sec-websocket-protocol']);
const MAX_BODY = 16 * 1024;
const MAX_WAIT_S = 120;

// A client address as the allowlist spells it: an IPv4-mapped IPv6 address is its IPv4.
export function normalizeAddress(addr) {
    return String(addr || '').toLowerCase().replace(/^::ffff:(?=\d+\.\d+\.\d+\.\d+$)/, '');
}
const clientAllowed = (view, socket) => !view.allowFrom || view.allowFrom.has(normalizeAddress(socket?.remoteAddress));

function sameSecret(a, b) {
    const ha = createHash('sha256').update(String(a)).digest();
    const hb = createHash('sha256').update(String(b)).digest();
    return timingSafeEqual(ha, hb);
}

// auto-browser's SessionStatus is active | closed | interrupted | failed. A deleted
// session stays readable as "closed"; a controller restart leaves every session that
// was active as "interrupted", which no longer has a browser behind it. Only
// "active" is live; "ended" is accepted too in case a later controller names it so.
export const ENDED_STATUSES = new Set(['closed', 'interrupted', 'failed', 'ended']);
const isEnded = (s) => ENDED_STATUSES.has(s?.status);
// The user is in the page: the agent waits (takeover) or is locked out (user).
export const HELD_STATUSES = new Set(['takeover', 'user']);
// The reason a link carries after the bridge released it on its way down.
export const SHUTDOWN_REASON = 'bridge_restarting';
// Control was released because the user's noVNC went away (app killed, network gone).
export const VIEWER_LEFT_REASON = 'viewer_left';
const ACTION_KINDS = new Set(['navigate', 'click', 'hover', 'select_option', 'type', 'press', 'scroll', 'wait', 'reload', 'go_back', 'go_forward', 'upload', 'eval_js', 'activate_tab', 'close_tab']);

// POST /live/<id>/nav {action, url?}: what the person holding control may do to the page.
export const NAV_ACTIONS = new Set(['back', 'forward', 'reload', 'goto']);
const NAV_MAX_URL = 2048;
// Schemes that are never prepended with https:// (they are refused as they are).
const NON_WEB_SCHEME = /^(javascript|data|file|chrome|chrome-extension|chrome-untrusted|devtools|about|view-source|blob|filesystem|ftp|ws|wss|mailto|intent|vbscript):/i;
/**
 * The URL a goto may open: http(s) only, or about:blank. Bare input ("example.com",
 * "localhost:3000/x") gets https://. Returns the URL string, or throws a 400.
 */
export function navUrl(input) {
    const bad = (why) => { throw Object.assign(new Error(why), { status: 400, code: 'bad_url' }); };
    if (typeof input !== 'string') bad('url is required');
    const raw = input.trim();
    if (!raw) bad('url is required');
    if (raw.length > NAV_MAX_URL) bad(`url is longer than ${NAV_MAX_URL} characters`);
    if (raw.toLowerCase() === 'about:blank') return 'about:blank';
    const hasScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(raw) || NON_WEB_SCHEME.test(raw);
    let u;
    try { u = new URL(hasScheme ? raw : `https://${raw}`); } catch { bad('not a valid URL'); }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') bad(`${u.protocol} URLs are not allowed`);
    if (!u.hostname) bad('not a valid URL');
    if (u.href.length > NAV_MAX_URL) bad(`url is longer than ${NAV_MAX_URL} characters`);
    return u.href;
}

// The approval the user is asked for: the link's own, for its current session, still pending.
export function pendingApproval(rec) {
    const a = rec.approval;
    if (!a || a.status !== 'pending' || a.sessionId !== rec.sessionId || rec.status === 'done') return null;
    return { id: a.id, kind: a.kind, summary: a.summary, details: a.details ?? [], asked_at: a.askedAt ?? null };
}

export function stateOf(rec) {
    return {
        status: rec.status, reason: rec.reason ?? null, url: rec.url ?? null, title: rec.title ?? null, last_action: rec.lastAction ?? null,
        approval: pendingApproval(rec),
        auto_approve: rec.autoApprove === true,
        auto_approved: Array.isArray(rec.autoApproved) ? rec.autoApproved.slice(0, AUTO_APPROVED_KEPT) : [],
    };
}

// Browser yolo: the note on an approval the bridge gives on the user's behalf, and how many of
// those a link remembers for its state.
export const AUTO_APPROVE_NOTE = 'Auto-approved (yolo mode)';
export const AUTO_APPROVED_KEPT = 5;

// auto-browser's approval status as the bridge names it.
const APPROVAL_STATUS = { pending: 'pending', approved: 'approved', executed: 'approved', rejected: 'denied' };

// {kind, target} from the MCP server: a known kind, and a short target with no control characters.
function cleanAction(a, at) {
    if (!a || typeof a !== 'object' || !ACTION_KINDS.has(a.kind)) return null;
    const target = typeof a.target === 'string' ? a.target.replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().slice(0, 120) : '';
    return { kind: a.kind, target: target || null, at };
}

export function createBridge({ client, store, config, now = Date.now, log = () => {} }) {
    const {
        publicBase = 'http://localhost:6090',
        novncUrl = 'http://localhost:6080/vnc.html?autoconnect=true&resize=scale',
        vncPassword = '',
        bridgeToken,
        frameCacheMs = 1000,
        // A frame read with an earlier frame in hand waits at most this long for the capture under
        // way, then answers with that earlier frame. A capture (screenshot + OCR scrub) takes
        // 1.4 s typically and over 4 s while an action runs: a viewer that waited for every one saw
        // reads slower than its spinner limit while nothing was wrong.
        frameWaitMs = 1500,
        // The earlier frame stands in only while it is younger than this. Past it the read waits
        // for the capture (or its failure), so a capture that is really stuck still shows as slow.
        frameStaleMs = 15_000,
        shareTtlMinutes = 1440,
        allowedHosts = null, // e.g. ['localhost:6090', '127.0.0.1:6090']; null admits any
        frameWidth = 1920,
        frameHeight = 1200,
        // async (rec) => {}: runs when the user ends a browser, before its session closes. A pod
        // manager hooks in here to save the login and stop the pod. Failures are logged only.
        onEnd = null,
        // A PodManager (lib/pods.mjs): each chat's link uses its own pod. null: every link uses `client`.
        pods = null,
        // async () => tools: auto-browser's tool list from any ready pod (for /api/tools).
        listTools = null,
        // How often open noVNC sockets are checked against their link and pod.
        tunnelCheckMs = 1000,
        // A held link whose last noVNC socket closed is released after this, unless one reconnects.
        viewerGraceMs = 10_000,
        // After /take, how long noVNC has to open its first socket before control is released.
        takeLoadMs = 60_000,
        linkSweepMs = 60_000,      // held links whose browser is gone are released this often
        // POST /live/<id>/nav: how long a navigation may take before answering with what loaded.
        navTimeoutMs = 10_000,
        // /state's editable_focused: an answer this young is reused, and a controller that has no
        // focus route (404) is not asked again for focusRetryMs.
        focusCacheMs = 250,
        focusRetryMs = 60_000,
    } = config;
    if (!bridgeToken) throw new Error('bridgeToken is required');

    const publicRoot = publicBase.replace(/\/+$/, '');
    const runtime = new Map(); // id -> {share, frame, inflight, waiters, metaAt}
    const rt = (id) => {
        let r = runtime.get(id);
        if (!r) runtime.set(id, (r = { share: null, frame: null, inflight: null, waiters: new Set(), approvalWaiters: new Set(), metaAt: 0 }));
        return r;
    };
    // `base` is the listener's public base: localhost for the loopback listener, the LAN address
    // for the LAN one (createBridge's listener()), so a link fetched over the LAN points back there.
    const linkUrl = (rec, base = publicRoot) => `${base}/live/${rec.id}`;
    // noVNC's own query (autoconnect, resize) from NOVNC_URL; its port is the shared browser's
    // noVNC, which a link without a pod uses. Upstreams are always 127.0.0.1, and the port always
    // comes from the bridge's own records, never from the request.
    const novncBase = new URL(novncUrl);
    const sharedNovncPort = Number(novncBase.port) || 80;
    const novncQuery = (() => { const q = new URLSearchParams(novncBase.search); q.delete('path'); return q.toString(); })();
    // Absolute, so current apps can decode it with URL(string:). The password stays in the fragment.
    function vncPageUrl(rec, password, base = publicRoot) {
        const prefix = `live/${rec.id}/vnc`;
        // noVNC 1.6 resolves path= against vnc.html's own URL, so a bare name lands on <prefix>/websockify.
        const query = [novncQuery, 'path=websockify'].filter(Boolean).join('&');
        return `${base}/${prefix}/vnc.html?${query}${password ? `#password=${encodeURIComponent(password)}` : ''}`;
    }

    // ── Per-chat pods ─────────────────────────────────────────────────────
    // A link with a chatKey (pods on) talks to its chat's pod, or to nothing while that pod is
    // asleep; any other link talks to the shared controller (`client`).
    const podLink = (rec) => !!(pods && rec.chatKey);
    const podOf = (rec) => (podLink(rec) ? pods.podOf(rec.chatKey) : null);
    const clientOf = (rec) => (podLink(rec) ? podOf(rec)?.client ?? null : client);
    function clientForSession(sid) {
        const chat = pods?.chatForSession(sid);
        if (!chat) return client;
        return pods.podOf(chat.chatKey)?.client ?? null;
    }
    function takeoverUrlOf(rec, base = publicRoot) {
        if (!podLink(rec)) return vncPageUrl(rec, vncPassword, base);
        const p = podOf(rec);
        if (!p) return null;
        return vncPageUrl(rec, p.vncPassword, base);
    }
    // Where this link's noVNC is: its pod's port (null while the pod is asleep), else the shared
    // one. `key` names the pod instance, so a socket notices when its pod stops or is replaced.
    function vncTarget(rec) {
        if (!podLink(rec)) return { port: sharedNovncPort, key: 'shared' };
        const p = podOf(rec);
        const port = Number(p?.novncPort);
        if (!p || !Number.isInteger(port) || port < 1 || port > 65535) return null;
        return { port, key: `pod:${p.slot}:${port}:${p.sessionId}` };
    }
    // live: a browser is up for this link right now (its pod runs and its session answered
    // lately, or it is starting), never for a done link. live_reason says why not.
    function liveOf(rec) {
        if (rec.status === 'done') {
            const l = podLink(rec) ? pods.liveness(rec.chatKey) : null;
            return { live: false, live_reason: rec.reason || 'done', ...(l ? { pod: l.pod === 'running' || l.pod === 'starting' ? 'asleep' : l.pod } : {}) };
        }
        if (!podLink(rec)) return { live: true, live_reason: null };
        const l = pods.liveness(rec.chatKey);
        return { live: l.live, live_reason: l.reason, pod: l.pod };
    }
    const podField = (rec) => liveOf(rec);
    // The runtime cache (share token, frame) belongs to one session: a pod restart starts afresh.
    function rtFor(rec) {
        const r = rt(rec.id);
        if (r.sid !== rec.sessionId) Object.assign(r, { sid: rec.sessionId, share: null, frame: null, metaAt: 0, focus: null, focusOffUntil: 0 });
        return r;
    }
    const asleepError = () => Object.assign(new Error('asleep'), { status: 503 });

    function setStatus(rec, status, reason) {
        store.update(rec, { status, reason: reason ?? null });
        // A closed browser has nothing left to approve.
        if (status === 'done' && rec.approval?.status === 'pending') settleApproval(rec, 'gone');
        if (!HELD_STATUSES.has(status)) {
            disarmLeave(rec.id);
            closeTunnels(rec.id, status === 'done' ? 'ended' : 'released');
            const r = rt(rec.id);
            for (const wake of r.waiters) wake();
            r.waiters.clear();
        }
    }

    // ── Approvals ──────────────────────────────────────────────────────────
    // An auto-browser approval the agent is waiting on, recorded on its link so the live view can
    // ask the user. It always belongs to the link's own session (checked against the controller's
    // record when it is registered, and again on every decision), so one chat can never see or
    // decide another chat's approval.
    function settleApproval(rec, status) {
        if (!rec.approval) return;
        store.update(rec, { approval: { ...rec.approval, status, decidedAt: now() } });
        const r = rt(rec.id);
        for (const wake of r.approvalWaiters) wake();
        r.approvalWaiters.clear();
    }

    function waitForApproval(rec, waitMs) {
        if (!pendingApproval(rec)) return Promise.resolve();
        return new Promise((resolve) => {
            const r = rt(rec.id);
            const wake = () => { clearTimeout(timer); r.approvalWaiters.delete(wake); resolve(); };
            const timer = setTimeout(wake, waitMs);
            r.approvalWaiters.add(wake);
        });
    }

    // Asks the controller where a pending approval stands: decided elsewhere (its own operator
    // API), gone (a restarted pod, an unknown id), or still pending.
    async function syncApproval(rec) {
        const a = pendingApproval(rec);
        if (!a) return;
        const c = clientOf(rec);
        if (!c) return;
        let record;
        try {
            record = await c.getApproval(a.id);
        } catch (err) {
            if (err.status === 404) settleApproval(rec, 'gone');
            return;
        }
        if (record?.session_id !== rec.sessionId) return settleApproval(rec, 'gone');
        const status = APPROVAL_STATUS[record?.status] ?? 'gone';
        if (status !== 'pending') settleApproval(rec, status);
    }

    // What became of approval `aid` on this link. A yolo-approved one is never stored in
    // rec.approval, only in rec.autoApproved, so it reads as approved from there.
    const approvalStatusOf = (rec, aid) => {
        if (rec.approval?.id === aid && rec.approval.sessionId === rec.sessionId) return rec.approval.status;
        if (Array.isArray(rec.autoApproved) && rec.autoApproved.some((e) => e?.id === aid)) return 'approved';
        return 'gone';
    };

    // POST /live/<id>/approve|deny: the user's decision on the link's own pending approval.
    async function decide(req, res, rec, approve) {
        let body;
        try { body = await readJson(req); } catch (err) { return send(res, err.status || 400, { error: err.message }); }
        const a = pendingApproval(rec);
        if (!a) return send(res, 409, { error: 'no_pending_approval', ...stateOf(rec), ...podField(rec) });
        if (body?.approval_id !== a.id) return send(res, 409, { error: 'approval_changed', ...stateOf(rec), ...podField(rec) });
        const c = clientOf(rec);
        if (!c) return send(res, 503, { error: 'asleep' });
        if (podLink(rec)) pods.touchViewer(rec.chatKey);
        try {
            const comment = approve ? 'Approved by the user from the live view' : 'Denied by the user from the live view';
            const record = await (approve ? c.approve(a.id, comment) : c.reject(a.id, comment));
            if (record?.session_id && record.session_id !== rec.sessionId) throw Object.assign(new Error('wrong session'), { status: 409 });
        } catch (err) {
            if (err.status === 409 || err.status === 404) {
                await syncApproval(rec);
                if (pendingApproval(rec)?.id === a.id) settleApproval(rec, 'gone');
                return send(res, 409, { error: 'approval_not_pending', approval_status: approvalStatusOf(rec, a.id), ...stateOf(rec), ...podField(rec) });
            }
            return send(res, 502, { error: 'approval_failed' });
        }
        settleApproval(rec, approve ? 'approved' : 'denied');
        log(`approval /live/${rec.id.slice(0, 6)}… ${approve ? 'approved' : 'denied'}`);
        return send(res, 200, { ok: true, approval_status: approvalStatusOf(rec, a.id), ...stateOf(rec), ...podField(rec) });
    }

    // ── Browser yolo ───────────────────────────────────────────────────────
    // Approves `aid` on the controller for this link's own session, as decide() does, and
    // records it on the link. Returns null when approved, else the error.
    async function yoloApprove(rec, c, aid, summary) {
        try {
            const record = await c.approve(aid, AUTO_APPROVE_NOTE);
            if (record?.session_id && record.session_id !== rec.sessionId) throw Object.assign(new Error('wrong session'), { status: 409 });
        } catch (err) {
            return err;
        }
        const entry = { id: aid, summary: summary || 'An action that needed approval.', at: now() };
        const before = Array.isArray(rec.autoApproved) ? rec.autoApproved : [];
        store.update(rec, { autoApproved: [entry, ...before.filter((e) => e.id !== aid)].slice(0, AUTO_APPROVED_KEPT) });
        log(`yolo mode /live/${rec.id.slice(0, 6)}… auto-approved ${aid}`);
        return null;
    }

    // POST /live/<id>/auto {on}: browser yolo on or off for this link's chat only.
    async function setAuto(req, res, rec) {
        let body;
        try { body = await readJson(req); } catch (err) { return send(res, err.status || 400, { error: err.message }); }
        if (typeof body?.on !== 'boolean') return send(res, 400, { error: 'on must be true or false' });
        store.update(rec, { autoApprove: body.on });
        log(`yolo mode /live/${rec.id.slice(0, 6)}… ${body.on ? 'on' : 'off'}`);
        // An approval already waiting when yolo goes on is approved too; its waiter wakes.
        const a = body.on ? pendingApproval(rec) : null;
        const c = a ? clientOf(rec) : null;
        if (a && c) {
            const err = await yoloApprove(rec, c, a.id, a.summary);
            if (!err) settleApproval(rec, 'approved');
            else if (err.status === 409 || err.status === 404) await syncApproval(rec);
        }
        return send(res, 200, { auto_approve: rec.autoApprove === true });
    }

    async function shareToken(rec, { fresh = false } = {}) {
        const r = rtFor(rec);
        const nowS = now() / 1000;
        if (!fresh && r.share && r.share.expiresAt - nowS > 300) return r.share.token;
        const c = clientOf(rec);
        if (!c) throw asleepError();
        const res = await c.share(rec.sessionId, shareTtlMinutes);
        r.share = { token: res.token, expiresAt: Number(res.expires_at) || nowS + shareTtlMinutes * 60 };
        return r.share.token;
    }

    // A link that is already done keeps its reason: user_ended stays user_ended once the closed
    // session is noticed.
    function sessionGone(rec) {
        if (rec.status !== 'done') setStatus(rec, 'done', 'session_closed');
    }

    // The user ended this browser from the app. The hook runs first, then the auto-browser session
    // closes and the link turns done (user_ended), which wakes an agent in wait_for_human. Ending an
    // ended browser changes nothing.
    async function endBrowser(rec) {
        if (rec.status === 'done' && rec.reason === 'user_ended') return stateOf(rec);
        if (onEnd) {
            try { await onEnd({ id: rec.id, sessionId: rec.sessionId }); } catch (err) { log(`end hook failed: ${err.message}`); }
        }
        try {
            // A pod's session is already closed by the hook (the pod is gone).
            const c = clientOf(rec);
            if (c) await c.closeSession(rec.sessionId);
        } catch (err) {
            if (err.status !== 404) log(`closing an ended browser failed: ${err.message}`);
        }
        const r = rt(rec.id);
        r.frame = null;
        r.share = null;
        setStatus(rec, 'done', 'user_ended');
        return stateOf(rec);
    }

    // The user put this browser to sleep from the app: like the idle stop, the login is saved and
    // the pod stops, and the next agent call or /take wakes it on the link's last page.
    async function sleepBrowser(rec) {
        if (!podLink(rec)) return [409, { error: 'pods_disabled', ...stateOf(rec) }];
        if (rec.status === 'done') return [409, { error: rec.reason || 'session_closed', ...stateOf(rec), ...podField(rec) }];
        const l = pods.liveness(rec.chatKey);
        if (l.pod === 'asleep' || l.pod === 'none') return [200, { ...stateOf(rec), ...podField(rec) }];
        // A browser on its way up has no pod to stop yet; the app asks again once it runs.
        if (l.pod === 'starting') return [409, { error: 'browser_starting', ...stateOf(rec), ...podField(rec) }];
        if (HELD_STATUSES.has(rec.status)) setStatus(rec, 'watching', 'user_slept');
        await pods.stopChat(rec.chatKey, 'slept');
        const r = rt(rec.id);
        r.frame = null;
        r.share = null;
        log(`sleep /live/${rec.id.slice(0, 6)}…: browser put to sleep`);
        return [200, { ...stateOf(rec), ...podField(rec) }];
    }

    async function captureFrame(rec) {
        const client = clientOf(rec);
        if (!client) throw asleepError();
        // A frame's age counts from when it was asked for: each takes most of a second to make
        // (the controller scrubs it), and an age from its end kept a viewer polling back to back
        // on one frame for a whole extra second.
        const asked = now();
        let observed;
        try {
            observed = await client.observeShared(await shareToken(rec));
        } catch (err) {
            if (err.status === 404) throw err;
            // A token signed before a controller restart, or expired: mint one and retry once.
            if (err.status !== 403 && err.status !== 401) throw err;
            observed = await client.observeShared(await shareToken(rec, { fresh: true }));
        }
        if (!observed?.screenshot_url) throw Object.assign(new Error('no frame'), { status: 502 });
        let image;
        try {
            image = await client.fetchFrame(observed.screenshot_url);
        } catch (err) {
            // The session answered observe, so it is live: a 404 here is a frame file the
            // controller already pruned, not a closed session. Try again next poll.
            throw Object.assign(new Error('frame file gone'), { status: 502 });
        }
        store.update(rec, { url: observed.url ?? rec.url, title: observed.title ?? rec.title });
        return { at: asked, ...image };
    }

    function frame(rec) {
        const r = rtFor(rec);
        if (r.frame && now() - r.frame.at < frameCacheMs) return Promise.resolve(r.frame);
        const capture = startCapture(rec, r);
        const earlier = r.frame;
        if (!earlier || now() - earlier.at >= frameStaleMs) return capture;
        // The new frame if it comes within frameWaitMs, else the one before it. A failed capture
        // still answers as a failure: the earlier frame covers slowness, not errors.
        let timer;
        const waited = new Promise((resolve) => { timer = setTimeout(() => resolve(earlier), frameWaitMs); });
        return Promise.race([capture, waited]).finally(() => clearTimeout(timer));
    }

    function startCapture(rec, r) {
        if (!r.inflight) {
            r.inflight = captureFrame(rec)
                .then((f) => (r.frame = f))
                .catch((err) => {
                    // Shared observe (or share minting) says 404 only when the controller has
                    // no live browser for the session: closed, interrupted by a restart, or
                    // unknown. Mark the link done now so /state stops saying watching.
                    if (err.status === 404) sessionGone(rec);
                    throw err;
                })
                .finally(() => { r.inflight = null; });
        }
        return r.inflight;
    }

    // /state polls this: at most every 5 s it asks auto-browser whether the session is
    // still live (and fills url/title the first time), so an interrupted or closed
    // session turns into done even when nobody is fetching frames.
    async function refreshMeta(rec) {
        const r = rtFor(rec);
        if (rec.status === 'done' || now() - r.metaAt < 5000) return;
        // An asleep pod has no session to ask about; the link stays as it is until the pod wakes.
        const client = clientOf(rec);
        if (!client) return;
        r.metaAt = now();
        try {
            const s = await client.getSession(rec.sessionId);
            if (isEnded(s)) return sessionGone(rec);
            if (!rec.url) store.update(rec, { url: s.current_url ?? null, title: s.title ?? null });
            // An approval decided or dropped elsewhere stops showing.
            if (pendingApproval(rec)) await syncApproval(rec);
        } catch (err) {
            if (err.status === 404) sessionGone(rec);
        }
    }

    // /state's editable_focused, while the person holds the browser: {} when it can't be told.
    // One read in flight per link, shared by the polls that arrive meanwhile.
    async function focusOf(rec) {
        if (!HELD_STATUSES.has(rec.status)) return {};
        const c = clientOf(rec);
        if (!c || typeof c.focus !== 'function') return {};
        const r = rtFor(rec);
        const field = (v) => (typeof v === 'boolean' ? { editable_focused: v } : {});
        if (r.focus && now() - r.focus.at < focusCacheMs) return field(r.focus.value);
        if (now() < (r.focusOffUntil ?? 0)) return {};
        if (!r.focusInflight) {
            const sid = rec.sessionId;
            r.focusInflight = c.focus(sid)
                .then((v) => { if (r.sid === sid) r.focus = { value: v, at: now() }; return v; })
                .catch((err) => { if (err.status === 404) r.focusOffUntil = now() + focusRetryMs; return null; })
                .finally(() => { r.focusInflight = null; });
        }
        return field(await r.focusInflight);
    }

    function waitForHandBack(rec, waitMs) {
        if (!HELD_STATUSES.has(rec.status)) return Promise.resolve();
        return new Promise((resolve) => {
            const r = rt(rec.id);
            const wake = () => { clearTimeout(timer); r.waiters.delete(wake); resolve(); };
            const timer = setTimeout(wake, waitMs);
            r.waiters.add(wake);
        });
    }

    // ── HTTP plumbing ──────────────────────────────────────────────────────
    const send = (res, code, body, headers = {}) => {
        const isBuf = Buffer.isBuffer(body);
        const payload = isBuf || typeof body === 'string' ? body : JSON.stringify(body);
        res.writeHead(code, {
            'Content-Type': isBuf ? 'application/octet-stream' : typeof body === 'string' ? 'text/plain; charset=utf-8' : 'application/json',
            'Cache-Control': 'no-store',
            'X-Content-Type-Options': 'nosniff',
            'Referrer-Policy': 'no-referrer',
            ...headers,
        });
        res.end(payload);
    };

    function readJson(req) {
        return new Promise((resolve, reject) => {
            let size = 0;
            const chunks = [];
            req.on('data', (c) => {
                size += c.length;
                if (size > MAX_BODY) { reject(Object.assign(new Error('body too large'), { status: 413 })); req.destroy(); return; }
                chunks.push(c);
            });
            req.on('end', () => {
                if (!chunks.length) return resolve({});
                try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
                catch { reject(Object.assign(new Error('invalid json'), { status: 400 })); }
            });
            req.on('error', reject);
        });
    }

    const sessionIdOf = (body) => {
        const sid = body?.session_id;
        if (typeof sid !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(sid)) {
            throw Object.assign(new Error('session_id is required'), { status: 400 });
        }
        return sid;
    };

    async function verifiedSession(sid, c = clientForSession(sid)) {
        if (!c) throw Object.assign(new Error('the browser is asleep'), { status: 404 });
        let s;
        try {
            s = await c.getSession(sid);
        } catch (err) {
            if (err.status === 404) throw Object.assign(new Error('unknown auto-browser session'), { status: 404 });
            throw Object.assign(new Error('auto-browser unavailable'), { status: 502 });
        }
        if (isEnded(s)) throw Object.assign(new Error(`auto-browser session is ${s.status}`), { status: 404 });
        return s;
    }

    async function api(req, res, path) {
        const auth = req.headers.authorization || '';
        const presented = auth.startsWith('Bearer ') ? auth.slice(7) : '';
        if (!presented || !sameSecret(presented, bridgeToken)) return send(res, 401, { error: 'unauthorized' });
        if (path === '/api/pods' && req.method === 'GET') return send(res, 200, pods ? { pods: true, ...pods.status() } : { pods: false });
        if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
        const body = await readJson(req);
        if (path.startsWith('/api/pod') || path === '/api/tools' || path === '/api/screen' || path === '/api/page-shot') return podApi(res, path, body);

        if (path === '/api/links' || path === '/api/takeover') {
            const { sid, rec: chatRec } = linkTarget(body);
            const session = await verifiedSession(sid, chatRec ? clientOf(chatRec) : undefined);
            const rec = chatRec || store.forSession(sid);
            if (session.current_url || session.title) store.update(rec, { url: session.current_url ?? rec.url, title: session.title ?? rec.title });
            if (rec.status === 'done' && rec.reason === 'session_closed') store.update(rec, { status: 'watching', reason: null });
            if (path === '/api/takeover') {
                const reason = typeof body.reason === 'string' && body.reason.trim() ? body.reason.trim().slice(0, 500) : 'The agent needs you';
                try {
                    await (clientOf(rec) || client).requestTakeover(sid, reason);
                } catch (err) {
                    return send(res, err.status === 404 ? 404 : 502, { error: 'takeover_request_failed' });
                }
                rt(rec.id).frame = null;
                setStatus(rec, 'takeover', reason);
            }
            return send(res, 200, { id: rec.id, url: linkUrl(rec), status: rec.status });
        }

        if (path === '/api/state') {
            let rec = null;
            if (body.chat_key !== undefined && body.chat_key !== null) rec = store.findChat(chatKeyOf(body));
            else if (body.session_id !== undefined && body.session_id !== null) rec = store.findSession(sessionIdOf(body));
            // Without a session or chat, a held link if any; with pods only a shared-stack one,
            // never another chat's.
            else rec = store.all().find((r) => HELD_STATUSES.has(r.status) && !podLink(r)) ?? null;
            if (!rec) return send(res, 200, { status: null });
            if (body.action !== undefined && !HELD_STATUSES.has(rec.status)) {
                const action = cleanAction(body.action, now());
                if (action) store.update(rec, { lastAction: action });
            }
            return send(res, 200, { id: rec.id, ...stateOf(rec), ...podField(rec) });
        }

        if (path === '/api/approval') {
            const aid = body?.approval_id;
            if (typeof aid !== 'string' || !APPROVAL_ID.test(aid)) return send(res, 400, { error: 'approval_id is required' });
            const { sid, rec: chatRec } = linkTarget(body);
            if (!chatRec) await verifiedSession(sid);
            const rec = chatRec || store.forSession(sid);
            const c = clientOf(rec);
            if (!c) return send(res, 503, { error: 'asleep' });
            let record;
            try {
                record = await c.getApproval(aid);
            } catch (err) {
                return send(res, err.status === 404 ? 404 : 502, { error: err.status === 404 ? 'unknown_approval' : 'auto-browser unavailable' });
            }
            // Only this link's own session: never another chat's approval.
            if (record?.session_id !== rec.sessionId) return send(res, 403, { error: 'not_this_session' });
            if (record.status !== 'pending') {
                return send(res, 409, { error: 'not_pending', approval_status: APPROVAL_STATUS[record.status] ?? 'gone' });
            }
            // Browser yolo: approved at once, never shown or waited on. Should that fail for any
            // reason but a decision made meanwhile, the user is asked as usual.
            if (rec.autoApprove === true) {
                const err = await yoloApprove(rec, c, aid, approvalSummary(record, rec.url).summary);
                if (!err) return send(res, 200, { id: rec.id, url: linkUrl(rec), approval: null, auto_approved: true, approval_status: 'approved' });
                if (err.status === 409 || err.status === 404) {
                    let current = null;
                    try { current = await c.getApproval(aid); } catch {}
                    return send(res, 409, { error: 'not_pending', approval_status: APPROVAL_STATUS[current?.status] ?? 'gone' });
                }
                log(`yolo mode /live/${rec.id.slice(0, 6)}… could not auto-approve ${aid}; asking the user`);
            }
            if (rec.approval?.id !== aid || rec.approval.status !== 'pending') {
                store.update(rec, { approval: { id: aid, sessionId: rec.sessionId, ...approvalSummary(record, rec.url), askedAt: now(), status: 'pending', decidedAt: null } });
            }
            return send(res, 200, { id: rec.id, url: linkUrl(rec), approval: pendingApproval(rec) });
        }

        if (path === '/api/approval/wait') {
            const found = typeof body.id === 'string' ? store.lookup(body.id) : null;
            if (!found) return send(res, 404, { error: 'unknown_link' });
            if (found.expired) return send(res, 410, { error: 'expired_link' });
            const { rec } = found;
            const aid = body.approval_id;
            if (typeof aid !== 'string' || !APPROVAL_ID.test(aid)) return send(res, 400, { error: 'approval_id is required' });
            if (pendingApproval(rec)?.id === aid) {
                const waitS = Math.max(0, Math.min(MAX_WAIT_S, Number(body.wait_s) || 30));
                await waitForApproval(rec, waitS * 1000);
                if (pendingApproval(rec)?.id === aid) await syncApproval(rec);
            }
            return send(res, 200, { approval_status: approvalStatusOf(rec, aid), ...stateOf(rec) });
        }

        if (path === '/api/wait' || path === '/api/release') {
            const found = typeof body.id === 'string' ? store.lookup(body.id) : null;
            if (!found) return send(res, 404, { error: 'unknown_link' });
            if (found.expired) return send(res, 410, { error: 'expired_link' });
            const { rec } = found;
            if (path === '/api/wait') {
                const waitS = Math.max(0, Math.min(MAX_WAIT_S, Number(body.wait_s) || 30));
                await waitForHandBack(rec, waitS * 1000);
            } else if (rec.status === 'takeover') {
                setStatus(rec, 'watching', typeof body.reason === 'string' ? body.reason.slice(0, 200) : 'timeout');
            }
            return send(res, 200, stateOf(rec));
        }
        return send(res, 404, { error: 'not_found' });
    }

    const chatKeyOf = (body) => {
        if (typeof body?.chat_key !== 'string' || !CHAT_KEY.test(body.chat_key)) throw Object.assign(new Error('chat_key must be 32 hex chars'), { status: 400 });
        return body.chat_key;
    };
    // /api/links and /api/takeover: {chat_key} names the chat's link (and its current session),
    // {session_id} a session as before.
    function linkTarget(body) {
        if (body.chat_key === undefined || body.chat_key === null) return { sid: sessionIdOf(body), rec: null };
        const rec = store.findChat(chatKeyOf(body));
        if (!rec || !rec.sessionId) throw Object.assign(new Error('this chat has no browser yet'), { status: 404 });
        return { sid: rec.sessionId, rec };
    }

    // The pod endpoints. Without a pod manager they answer 409 pods_disabled, which tells the
    // MCP server to use the shared controller.
    async function podApi(res, path, body) {
        if (!pods) return send(res, 409, { error: 'pods_disabled' });
        try {
            if (path === '/api/pod') {
                let key;
                if (body.chat_key !== undefined) key = chatKeyOf(body);
                else {
                    const chat = pods.chatForSession(sessionIdOf(body));
                    if (!chat) return send(res, 404, { error: 'unknown session' });
                    key = chat.chatKey;
                }
                const source = typeof body.source === 'string' ? body.source.slice(0, 32) : null;
                // forked_from: the parent chat's key, sent by the MCP server of a forked or side
                // chat (from the daemon's HAPPY_FORKED_FROM_SESSION_ID, never a tool argument).
                let forkedFrom = null;
                if (body.forked_from !== undefined && body.forked_from !== null) {
                    if (typeof body.forked_from !== 'string' || !CHAT_KEY.test(body.forked_from) || body.forked_from === key) {
                        return send(res, 400, { error: 'forked_from must be 32 hex chars and not the chat itself' });
                    }
                    forkedFrom = body.forked_from;
                }
                const d = await pods.ensure(key, { source, verify: body.verify === true, check: body.check === true, ...(forkedFrom ? { forkedFrom } : {}) });
                const rec = store.findChat(key);
                return send(res, 200, { ...d, url: rec ? linkUrl(rec) : null, status: rec?.status ?? null });
            }
            if (path === '/api/pod/close') {
                const key = chatKeyOf(body);
                const stopped = await pods.stopChat(key, 'closed');
                const rec = store.findChat(key);
                if (rec) {
                    const r = rt(rec.id);
                    r.frame = null;
                    r.screen = null;
                    r.share = null;
                    if (rec.status !== 'done') setStatus(rec, 'done', 'session_closed');
                }
                return send(res, 200, { closed: stopped, pod: pods.podState(key) });
            }
            if (path === '/api/screen') {
                const label = typeof body.label === 'string' && body.label ? body.label.slice(0, 100) : 'manual';
                const view = body.view ?? null;
                if (view !== null && view !== 'desktop' && view !== 'tab') return send(res, 400, { error: 'bad_view' });
                // Unredacted only when asked for in so many words.
                return send(res, 200, await pods.screenShot(chatKeyOf(body), { activate: body.activate !== false, label, redact: body.redact !== false, view }));
            }
            if (path === '/api/page-shot') {
                const label = typeof body.label === 'string' && body.label ? body.label.slice(0, 100) : 'manual';
                return send(res, 200, await pods.pageShot(chatKeyOf(body), { label, redact: body.redact !== false }));
            }
            if (path === '/api/tools') {
                if (!listTools) return send(res, 503, { error: 'no tool list' });
                return send(res, 200, { tools: await listTools() });
            }
        } catch (err) {
            const status = err.status && err.status >= 400 && err.status < 600 ? err.status : 503;
            return send(res, status, { error: err.message, ...(err.code ? { code: err.code } : {}) });
        }
        return send(res, 404, { error: 'not_found' });
    }

    // GET /live/chat/<chat_key>: the chat's link, so the app can show a chat's live browser
    // without finding the link in the chat's text. live: a browser is up (or starting) for it.
    function chatLink(res, key, base) {
        const rec = store.findChat(key);
        if (!rec) return send(res, 404, { error: 'no_link' });
        return send(res, 200, { id: rec.id, url: linkUrl(rec, base), ...stateOf(rec), ...liveOf(rec) });
    }

    // POST /live/<id>/nav: back, forward, reload or goto on the link's own session, for the
    // person holding control only. A slow page answers with what has loaded after navTimeoutMs.
    async function nav(req, res, rec) {
        if (!HELD_STATUSES.has(rec.status)) return send(res, 409, { ok: false, error: 'not_in_control', ...stateOf(rec) });
        let body;
        try { body = await readJson(req); } catch (err) { return send(res, err.status || 400, { ok: false, error: err.message }); }
        const action = body?.action;
        if (!NAV_ACTIONS.has(action)) return send(res, 400, { ok: false, error: 'action must be back, forward, reload or goto' });
        let url = null;
        if (action === 'goto') {
            try { url = navUrl(body.url); } catch (err) { return send(res, 400, { ok: false, error: err.message, code: err.code }); }
        }
        const c = clientOf(rec);
        if (!c) return send(res, 503, { ok: false, error: 'asleep' });
        if (podLink(rec)) pods.touchViewer(rec.chatKey);
        let s, timedOut = false;
        try {
            s = await c.navigate(rec.sessionId, action, url, navTimeoutMs);
        } catch (err) {
            if (!err.timedOut) return send(res, err.status === 404 ? 410 : 502, { ok: false, error: err.status === 404 ? 'session_closed' : err.message });
            timedOut = true;
            try { s = await c.getSession(rec.sessionId); } catch { s = null; }
        }
        if (s?.current_url || s?.title) store.update(rec, { url: s.current_url ?? rec.url, title: s.title ?? rec.title });
        log(`nav /live/${rec.id.slice(0, 6)}… ${action}${timedOut ? ' (timed out)' : ''}`);
        // History position is not exposed by auto-browser (raw CDP is refused), so these are unknown.
        return send(res, 200, { ok: true, url: rec.url ?? null, title: rec.title ?? null, can_go_back: null, can_go_forward: null, ...(timedOut ? { timed_out: true } : {}) });
    }

    async function live(req, res, id, sub, base) {
        const found = store.lookup(id);
        const wantsHtml = !sub;
        if (!found) {
            return wantsHtml ? send(res, 404, renderGone('This live view does not exist.'), { 'Content-Type': 'text/html; charset=utf-8' })
                : send(res, 404, { error: 'unknown_link' });
        }
        if (found.expired) {
            return wantsHtml ? send(res, 410, renderGone('This live view has expired.'), { 'Content-Type': 'text/html; charset=utf-8' })
                : send(res, 410, { error: 'expired_link' });
        }
        const { rec } = found;
        store.touch(rec);

        if (sub === '/take' || sub === '/release' || sub === '/done' || sub === '/end') {
            if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'POST' });
            if (sub === '/end') return send(res, 200, await endBrowser(rec));
            if (sub === '/take') {
                if (rec.status === 'done') return send(res, 409, { error: rec.reason || 'session_closed', ...stateOf(rec) });
                // An asleep pod is woken; the app asks again once it runs.
                if (podLink(rec) && !podOf(rec)) {
                    pods.touchViewer(rec.chatKey);
                    pods.wake(rec.chatKey);
                    return send(res, 202, { ...stateOf(rec), live: true, live_reason: null, pod: 'starting' });
                }
                // From takeover the agent is already waiting for the user: nothing changes.
                if (rec.status !== 'takeover' && rec.status !== 'user') setStatus(rec, 'user', 'user_took_control');
                if (!hasTunnel(rec.id)) armLeave(rec.id, takeLoadMs);
                return send(res, 200, { ...stateOf(rec), ...podField(rec), novnc_url: takeoverUrlOf(rec, base) });
            }
            if (HELD_STATUSES.has(rec.status)) releaseHeld(rec, 'user_released');
            return send(res, 200, { ...stateOf(rec), ...podField(rec) });
        }
        if (sub === '/sleep') {
            if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'POST' });
            const [code, body] = await sleepBrowser(rec);
            return send(res, code, body);
        }
        if (sub === '/nav') {
            if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'POST' });
            return nav(req, res, rec);
        }
        if (sub === '/approve' || sub === '/deny') {
            if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'POST' });
            return decide(req, res, rec, sub === '/approve');
        }
        if (sub === '/auto') {
            if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'POST' });
            return setAuto(req, res, rec);
        }
        if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'GET' });

        // Polls count as viewer activity, which keeps a pod from its idle stop; they never wake one.
        if (podLink(rec)) pods.touchViewer(rec.chatKey);
        if (sub === '/state') {
            await refreshMeta(rec);
            const focus = await focusOf(rec);
            return send(res, 200, { ...stateOf(rec), ...podField(rec), ...focus });
        }
        if (sub === '/frame.jpg') {
            if (podLink(rec) && !podOf(rec)) return send(res, 503, { error: 'asleep' });
            try {
                const f = await frame(rec);
                if (podLink(rec)) pods.sessionSeen(rec.chatKey);
                return send(res, 200, f.body, { 'Content-Type': f.contentType });
            } catch (err) {
                if (err.status === 503) return send(res, 503, { error: 'asleep' });
                return send(res, err.status === 404 ? 404 : 502, { error: err.status === 404 ? 'session_closed' : 'frame_unavailable' });
            }
        }
        if (sub === '/screen.png') {
            if (!podLink(rec)) return send(res, 404, { error: 'no_screen' });
            if (!podOf(rec)) return send(res, 503, { error: 'asleep' });
            try {
                const shot = await screenOf(rec);
                return send(res, 200, shot, { 'Content-Type': 'image/png' });
            } catch (err) {
                return send(res, err.status === 503 ? 503 : 502, { error: err.status === 503 ? 'asleep' : 'screen_unavailable' });
            }
        }
        const nonce = randomBytes(12).toString('base64');
        // The page's own Take control link carries no password: a GET of the page (by anyone the
        // link reaches, an agent's fetch included) never shows it. POST /take answers with it.
        const pageTake = takeoverUrlOf(rec, base);
        return send(res, 200, renderPage({ id: rec.id, state: stateOf(rec), takeoverUrl: pageTake ? pageTake.split('#')[0] : `${linkUrl(rec, base)}`, nonce, frameWidth, frameHeight }), {
            'Content-Type': 'text/html; charset=utf-8',
            'Content-Security-Policy': `default-src 'none'; img-src 'self' blob:; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'`,
        });
    }

    // A link's screen.png: one capture in flight per link, and a capture less than a second old
    // is served again, so a polling viewer costs the pod at most one capture a second.
    async function screenOf(rec) {
        const r = rt(rec.id);
        if (r.screen && now() - r.screen.at < 1000) return r.screen.body;
        if (!r.screenInflight) {
            r.screenInflight = pods.screen(rec.chatKey)
                .then((shot) => { r.screen = { at: now(), body: Buffer.from(shot.data, 'base64') }; return r.screen.body; })
                .finally(() => { r.screenInflight = null; });
        }
        return r.screenInflight;
    }

    // ── noVNC through the bridge ──────────────────────────────────────────
    const rawPathOf = (req) => (String(req.url || '').startsWith('/') ? String(req.url).split('?')[0] : '');

    async function vncStatic(req, res, raw, setRoute) {
        const m = VNC_FILE.exec(raw);
        if (!m) { setRoute('/live/…/vnc (refused)'); return send(res, 400, { error: 'bad_path' }); }
        const [, id, file] = m;
        setRoute(`/live/${id.slice(0, 6)}…/vnc/${file}`);
        if (file === 'websockify') return send(res, 426, { error: 'upgrade_required' });
        if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'GET' });
        const found = store.lookup(id);
        if (!found) return send(res, 404, { error: 'unknown_link' });
        if (found.expired) return send(res, 410, { error: 'expired_link' });
        const { rec } = found;
        const target = vncTarget(rec);
        if (!target) return send(res, 503, { error: 'asleep' });
        store.touch(rec);
        if (podLink(rec)) pods.touchViewer(rec.chatKey);
        await new Promise((resolve) => {
            const headers = { host: `127.0.0.1:${target.port}` };
            for (const h of VNC_REQ_HEADERS) if (typeof req.headers[h] === 'string') headers[h] = req.headers[h];
            const up = httpRequest({ host: '127.0.0.1', port: target.port, method: req.method, path: `/${file}`, headers, timeout: 15_000 }, (ur) => {
                const out = { 'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' };
                for (const h of VNC_RES_HEADERS) if (ur.headers[h] !== undefined) out[h] = ur.headers[h];
                res.writeHead(ur.statusCode || 502, out);
                ur.pipe(res);
                ur.on('end', resolve);
                ur.on('error', () => { res.destroy(); resolve(); });
            });
            up.on('timeout', () => up.destroy(new Error('timeout')));
            up.on('error', () => { if (!res.headersSent) send(res, 502, { error: 'novnc_unavailable' }); else res.destroy(); resolve(); });
            res.on('close', () => { up.destroy(); resolve(); });
            up.end();
        });
    }

    function releaseHeld(rec, reason) {
        setStatus(rec, 'watching', reason);
        // The user often just logged in: keep that login now, not only when the pod stops.
        if (podLink(rec)) pods.checkpointAuth(rec.chatKey, { force: true }).catch(() => {});
    }

    const tunnels = new Set(); // {id, key, socket, up}
    let tunnelTimer = null;
    const hasTunnel = (id) => [...tunnels].some((t) => t.id === id);
    // Held links with no noVNC socket, waiting to be released: id -> timeout.
    const leaveTimers = new Map();
    function disarmLeave(id) {
        clearTimeout(leaveTimers.get(id));
        leaveTimers.delete(id);
    }
    function armLeave(id, ms) {
        disarmLeave(id);
        const timer = setTimeout(() => {
            leaveTimers.delete(id);
            const found = store.lookup(id);
            if (!found || found.expired || !HELD_STATUSES.has(found.rec.status) || hasTunnel(id)) return;
            log(`vnc /live/${id.slice(0, 6)}…: no viewer for ${Math.round(ms / 1000)} s; releasing control`);
            releaseHeld(found.rec, VIEWER_LEFT_REASON);
        }, ms);
        timer.unref?.();
        leaveTimers.set(id, timer);
    }
    function closeTunnel(t, why) {
        if (!tunnels.delete(t)) return;
        t.socket.destroy();
        t.up.destroy();
        log(`vnc socket /live/${t.id.slice(0, 6)}… closed (${why})`);
        if (!tunnels.size && tunnelTimer) { clearInterval(tunnelTimer); tunnelTimer = null; }
        // The viewer went away while still holding control: release it unless noVNC comes back.
        if (t.open && (why === 'viewer_closed' || why === 'upstream_closed') && !hasTunnel(t.id)) armLeave(t.id, viewerGraceMs);
    }
    function closeTunnels(id, why) {
        for (const t of [...tunnels]) if (t.id === id) closeTunnel(t, why);
    }
    // A socket lives only while its link is held and its pod is the one it was opened to.
    function checkTunnels() {
        for (const t of [...tunnels]) {
            const found = store.lookup(t.id);
            if (!found || found.expired) { closeTunnel(t, 'expired'); continue; }
            const { rec } = found;
            if (!HELD_STATUSES.has(rec.status)) { closeTunnel(t, 'released'); continue; }
            if (vncTarget(rec)?.key !== t.key) { closeTunnel(t, 'pod_stopped'); continue; }
            // The phone is in noVNC, not polling the page: that still counts as viewing.
            store.touch(rec);
            if (podLink(rec)) pods.touchViewer(rec.chatKey);
        }
    }

    // server.on('upgrade'): the noVNC socket of a held link, piped to that link's own noVNC.
    // Every other upgrade is refused.
    function upgradeOn(view, req, socket, head) {
        let route = 'upgrade';
        socket.on('error', () => {});
        const refuse = (code, text) => {
            log(`UPGRADE ${route} ${code}`);
            socket.end(`HTTP/1.1 ${code} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
            socket.once('finish', () => socket.destroy());
        };
        if (!clientAllowed(view, req.socket)) { route = 'lan-refused'; return refuse(403, 'Forbidden'); }
        if (view.hosts && !view.hosts.includes(String(req.headers.host || '').toLowerCase())) { route = 'bad-host'; return refuse(421, 'Misdirected Request'); }
        const m = VNC_SOCKET.exec(rawPathOf(req));
        if (!m) return refuse(404, 'Not Found');
        const id = m[1];
        route = `/live/${id.slice(0, 6)}…/vnc/websockify`;
        const key = req.headers['sec-websocket-key'];
        if (req.method !== 'GET' || String(req.headers.upgrade || '').toLowerCase() !== 'websocket'
            || req.headers['sec-websocket-version'] !== '13' || typeof key !== 'string' || !WS_KEY.test(key)) return refuse(400, 'Bad Request');
        const found = store.lookup(id);
        if (!found) return refuse(404, 'Not Found');
        if (found.expired) return refuse(410, 'Gone');
        const { rec } = found;
        if (!HELD_STATUSES.has(rec.status)) return refuse(403, 'Forbidden');
        const target = vncTarget(rec);
        if (!target) return refuse(503, 'Service Unavailable');

        const up = netConnect({ host: '127.0.0.1', port: target.port });
        const t = { id, key: target.key, socket, up };
        tunnels.add(t);
        if (!tunnelTimer) { tunnelTimer = setInterval(checkTunnels, tunnelCheckMs); tunnelTimer.unref?.(); }
        store.touch(rec);
        if (podLink(rec)) pods.touchViewer(rec.chatKey);

        // websockify answers 403 Invalid Origin unless Origin matches its own host, so the bridge
        // speaks as that origin. The viewer's own Host was checked above and its link id is the capability.
        const lines = ['GET /websockify HTTP/1.1', `Host: 127.0.0.1:${target.port}`, `Origin: http://127.0.0.1:${target.port}`,
            'Upgrade: websocket', 'Connection: Upgrade', `Sec-WebSocket-Key: ${key}`, 'Sec-WebSocket-Version: 13'];
        const proto = req.headers['sec-websocket-protocol'];
        if (typeof proto === 'string' && WS_PROTOCOL.test(proto)) lines.push(`Sec-WebSocket-Protocol: ${proto}`);
        up.write(`${lines.join('\r\n')}\r\n\r\n`);
        if (head?.length) up.write(head);

        let buf = Buffer.alloc(0);
        let open = false;
        const fail = () => {
            if (!tunnels.has(t)) return;
            if (open) return closeTunnel(t, 'upstream_closed');
            tunnels.delete(t);
            if (!tunnels.size && tunnelTimer) { clearInterval(tunnelTimer); tunnelTimer = null; }
            up.destroy();
            refuse(502, 'Bad Gateway');
        };
        const onData = (chunk) => {
            buf = Buffer.concat([buf, chunk]);
            const end = buf.indexOf('\r\n\r\n');
            if (end < 0) { if (buf.length > 16 * 1024) fail(); return; }
            up.removeListener('data', onData);
            const [status, ...headers] = buf.subarray(0, end).toString('latin1').split('\r\n');
            if (!/^HTTP\/1\.1 101\b/.test(status)) return fail();
            const kept = headers.filter((l) => WS_RES_HEADERS.has(l.slice(0, l.indexOf(':')).trim().toLowerCase()));
            socket.write(`HTTP/1.1 101 Switching Protocols\r\n${kept.map((l) => `${l}\r\n`).join('')}\r\n`);
            const rest = buf.subarray(end + 4);
            if (rest.length) socket.write(rest);
            open = true;
            t.open = true;
            disarmLeave(id);
            log(`UPGRADE ${route} 101`);
            up.pipe(socket);
            socket.pipe(up);
        };
        up.on('data', onData);
        up.on('error', fail);
        up.on('close', fail);
        // Upgrade sockets are half-open (http.Server's allowHalfOpen): a FIN alone never fires
        // 'close', so either side ending ends the tunnel.
        up.on('end', fail);
        socket.on('end', () => closeTunnel(t, 'viewer_closed'));
        socket.on('close', () => closeTunnel(t, 'viewer_closed'));
    }

    // A link the user holds while its browser is gone (asleep, crashed, reaped) holds nothing:
    // it is released (reason browser_asleep), so no window shows a phantom browser in control.
    // A browser that is starting is left alone. Returns how many were released.
    function sweepLinks() {
        if (!pods) return 0;
        let n = 0;
        for (const rec of store.all()) {
            if (!podLink(rec) || !HELD_STATUSES.has(rec.status)) continue;
            const l = pods.liveness(rec.chatKey);
            if (l.live) continue;
            setStatus(rec, 'watching', 'browser_asleep');
            log(`sweep: /live/${rec.id.slice(0, 6)}… was held with its browser ${l.pod}; released`);
            n++;
        }
        return n;
    }
    let linkSweepTimer = null;
    if (pods && linkSweepMs > 0) { linkSweepTimer = setInterval(() => { try { sweepLinks(); } catch (e) { log(`sweep: ${e.message}`); } }, linkSweepMs); linkSweepTimer.unref?.(); }

    function close() {
        if (linkSweepTimer) { clearInterval(linkSweepTimer); linkSweepTimer = null; }
        for (const id of [...leaveTimers.keys()]) disarmLeave(id);
        for (const t of [...tunnels]) closeTunnel(t, 'shutdown');
    }

    // The bridge is stopping (SIGTERM/SIGINT): every held link is released the same way the
    // user's Release control does it, so noVNC sockets close and waiting agents get an answer
    // (reason bridge_restarting) instead of a dropped connection. The pods and links stay; the
    // agent asks again once the bridge is back. Each pod's login is saved first, as a release
    // does, for at most `checkpointMs`. Returns the released links (id prefix and title).
    async function shutdown({ checkpointMs = 2000 } = {}) {
        const held = store.all().filter((r) => HELD_STATUSES.has(r.status));
        const saves = [];
        for (const rec of held) {
            setStatus(rec, 'watching', SHUTDOWN_REASON);
            if (podLink(rec)) saves.push(pods.checkpointAuth(rec.chatKey, { force: true }).catch(() => {}));
            log(`shutdown: released /live/${rec.id.slice(0, 6)}…`);
        }
        close();
        if (saves.length) {
            let timer;
            await Promise.race([Promise.all(saves), new Promise((r) => { timer = setTimeout(r, checkpointMs); })]);
            clearTimeout(timer);
        }
        store.flush();
        return held.map((r) => ({ id: r.id.slice(0, 8), title: r.title ?? null }));
    }

    async function handle(view, req, res) {
        const started = now();
        const url = new URL(req.url, 'http://bridge.invalid');
        const path = url.pathname;
        let route = path;
        res.on('finish', () => log(`${req.method} ${route} ${res.statusCode} ${now() - started}ms`));
        try {
            // A LAN listener serves only its allowlisted clients, before any routing.
            if (!clientAllowed(view, req.socket)) {
                route = 'lan-refused';
                res.shouldKeepAlive = false;
                return send(res, 403, { error: 'forbidden' }, { Connection: 'close' });
            }
            if (view.hosts && !view.hosts.includes(String(req.headers.host || '').toLowerCase())) {
                route = 'bad-host';
                return send(res, 421, { error: 'misdirected_request' });
            }
            if (path === '/healthz') return send(res, 200, { ok: true });
            // The MCP server's private routes are on loopback only.
            if (path.startsWith('/api/')) return view.api ? await api(req, res, path) : send(res, 404, { error: 'not_found' });
            const raw = rawPathOf(req);
            if (VNC_PREFIX.test(raw) || VNC_PREFIX.test(path)) return await vncStatic(req, res, raw, (r) => { route = r; });
            const c = CHAT_ROUTE.exec(path);
            if (c) {
                route = `/live/chat/${c[1].slice(0, 6)}…`;
                if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'GET' });
                return chatLink(res, c[1], view.base);
            }
            const m = LIVE_ROUTE.exec(path);
            if (m) {
                route = `/live/${m[1].slice(0, 6)}…${m[2] || ''}`;
                return await live(req, res, m[1], m[2], view.base);
            }
            return send(res, 404, { error: 'not_found' });
        } catch (err) {
            const status = err.status && err.status >= 400 && err.status < 600 ? err.status : 500;
            if (!res.headersSent) send(res, status, { error: status === 500 ? 'internal_error' : err.message });
        }
    }

    // A listener's view of the bridge. The default one (handler, upgrade) is the loopback
    // listener: config.allowedHosts, every client, the private /api routes, publicBase. A LAN
    // listener passes its own Host list, the client addresses it serves (allowFrom; anyone else
    // gets 403 before any routing), its own base for the absolute URLs it returns, and api: false.
    function listener({ allowedHosts: hosts = allowedHosts, allowFrom = null, publicBase: base = publicRoot, api: withApi = true } = {}) {
        const view = {
            hosts: hosts ? hosts.map((h) => String(h).toLowerCase()) : null,
            allowFrom: allowFrom ? new Set(allowFrom.map(normalizeAddress)) : null,
            base: String(base).replace(/\/+$/, ''),
            api: withApi,
        };
        return { handler: (req, res) => handle(view, req, res), upgrade: (req, socket, head) => upgradeOn(view, req, socket, head), allows: (addr) => !view.allowFrom || view.allowFrom.has(normalizeAddress(addr)) };
    }
    const loopback = listener();

    return { handler: loopback.handler, upgrade: loopback.upgrade, listener, close, shutdown, store, linkUrl, stateOf, sweepLinks };
}
