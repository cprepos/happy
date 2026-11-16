// What the user sees of an auto-browser approval: a short, scrubbed summary built from the
// controller's approval record. Never the typed text, a field's value, a tool's arguments, a
// file path or a query string; the agent's own reason is shown with anything that looks like a
// secret masked. For a tool call (eval_js and the like) the controller's record carries only a raw
// argument preview, never shown; the reason and the script preview come from the bridge's MCP
// server instead (`extras`), which holds the call's own arguments.

export const APPROVAL_ID = /^[A-Za-z0-9_-]{1,64}$/;

const KIND_LABEL = {
    write: 'change the page',
    upload: 'upload a file',
    post: 'post or send something',
    payment: 'make a payment',
    account_change: 'change account settings',
    destructive: 'delete something',
};

const TOOL_LABEL = {
    'browser.save_auth_state': 'Save this browser\'s login state',
    'browser.save_auth_profile': 'Save this browser\'s login as a profile',
    'browser.set_cookies': 'Set cookies in the browser',
    'browser.set_local_storage': 'Change the page\'s stored data',
    'browser.cdp_attach': 'Attach a debugger to the browser',
    'browser.eval_js': 'Run JavaScript in the page',
};

// Tool-call tools (by their local, API-safe names) that take the bridge's own `reason` argument.
export const REASON_TOOLS = new Set(Object.keys(TOOL_LABEL).map((t) => t.replace(/[^a-zA-Z0-9_-]/g, '_')));
// The one of them whose reason is required, and whose script is shown as a code preview.
export const CODE_TOOL = 'browser.eval_js';
export const REASON_MAX_INPUT = 300;
export const CODE_MAX = 1500;
export const AGENT_SAYS = 'Agent says: ';
export const NO_REASON = 'The agent didn\'t say why';

const MAX_REASON = 240;
const MASK = '•••';

// Whatever a reason line may carry that looks like a secret: key=value pairs for password-ish
// keys, bearer tokens, and long unbroken token-like runs.
const SECRET_PAIR = /\b(pass(?:word|wd|code|phrase)?|pwd|pin|secret|token|api[_ -]?key|otp|cvv|cvc|ssn)\b(\s*[:=]\s*|\s+(?:is|of)\s+)\S+/gi;
const SECRETISH = [
    /\bbearer\s+\S+/gi,
    /\b[A-Za-z0-9+/_=-]{24,}\b/g,
    /\b\d{12,19}\b/g, // card-like numbers
];

const oneLine = (s) => String(s).replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim();

function clip(s, n) {
    const t = oneLine(s);
    return t.length > n ? `${t.slice(0, n - 1)}…` : t;
}

/** The agent's reason with the typed text and secret-looking parts masked. */
export function scrubReason(reason, hidden = []) {
    if (typeof reason !== 'string' || !reason.trim()) return null;
    let s = oneLine(reason);
    for (const h of hidden) {
        if (typeof h !== 'string') continue;
        const v = h.trim();
        if (v.length < 3) continue;
        s = s.split(v).join(MASK);
    }
    s = s.replace(SECRET_PAIR, (m, key, sep) => `${key}${sep}${MASK}`);
    for (const re of SECRETISH) s = s.replace(re, MASK);
    return clip(s, MAX_REASON) || null;
}

/**
 * A page script as the user may see it: line breaks and indentation kept, other control
 * characters dropped, secret-looking parts masked as in a reason, cut at about CODE_MAX chars.
 */
export function scrubCode(code) {
    if (typeof code !== 'string') return null;
    let s = code.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0008\u000b-\u001f\u007f]+/g, ' ');
    // Cut first (a little over, so masking at the edge still sees whole tokens), then mask, then cut.
    if (s.length > CODE_MAX + 200) s = s.slice(0, CODE_MAX + 200);
    s = s.replace(SECRET_PAIR, (m, key, sep) => `${key}${sep}${MASK}`);
    for (const re of SECRETISH) s = s.replace(re, MASK);
    s = s.replace(/^\n+|\s+$/g, '');
    if (!s) return null;
    return s.length > CODE_MAX ? `${s.slice(0, CODE_MAX - 1)}…` : s;
}

/** host + path of an http(s) URL, without query, fragment or credentials; null otherwise. */
export function placeOf(url) {
    if (typeof url !== 'string') return null;
    try {
        const u = new URL(url);
        if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
        const path = u.pathname === '/' ? '' : u.pathname;
        return clip(`${u.host}${path}`, 120);
    } catch {
        return null;
    }
}

function actionLine(a) {
    switch (a?.action) {
        case 'click': {
            const label = typeof a.label === 'string' ? scrubReason(a.label, [a.text, a.value, a.username]) : null;
            return label ? `Click "${clip(label, 60)}"` : 'Click on the page';
        }
        case 'press': return a.key && /^[A-Za-z0-9+ ]{1,40}$/.test(a.key) ? `Press ${a.key}` : 'Press a key';
        case 'navigate': {
            const p = placeOf(a.url);
            return p ? `Open ${p}` : 'Open a page';
        }
        case 'type': {
            const n = typeof a.text === 'string' ? a.text.length : 0;
            return n ? `Type text (${n} characters, hidden)` : 'Type text';
        }
        case 'select_option': return 'Choose an option in a list';
        case 'upload': return 'Upload a file';
        case 'hover': return 'Point at something on the page';
        case 'scroll': return 'Scroll the page';
        default: return a?.action ? `Do “${clip(String(a.action).replace(/_/g, ' '), 40)}” in the page` : 'Do something in the page';
    }
}

/** For a tool_call approval: the tool's name, from the record's "<name> sha256:<digest>" text. */
function toolNameOf(record) {
    const t = record?.action?.text;
    if (typeof t !== 'string') return null;
    const name = t.split(' sha256:')[0].trim();
    return /^[a-z0-9_.]{1,80}$/i.test(name) ? name : null;
}

/**
 * {kind, summary, details[], code} for an approval record. `pageUrl` is the link's last known page,
 * used when the record has no observation. `extras` is what the bridge's MCP server sent with the
 * approval: the agent's `reason` for a tool call and, for eval_js only, the script as `code`.
 * `code` is null for every other approval.
 */
export function approvalSummary(record, pageUrl = null, extras = {}) {
    const kind = KIND_LABEL[record?.kind] ? record.kind : 'write';
    const summary = `The agent wants to ${KIND_LABEL[kind]}.`;
    const details = [];
    let code = null;
    const where = placeOf(record?.observation?.url) || placeOf(pageUrl);
    if (record?.origin === 'tool_call') {
        const tool = toolNameOf(record);
        details.push(TOOL_LABEL[tool] || (tool ? `Use the tool ${tool}` : 'Use a browser tool'));
        const reason = scrubReason(extras?.reason);
        details.push(reason ? `${AGENT_SAYS}${reason}` : NO_REASON);
        if (tool === CODE_TOOL) code = scrubCode(extras?.code);
    } else {
        const a = record?.action || {};
        details.push(actionLine(a));
        const reason = scrubReason(a.reason || record?.reason, [a.text, a.value, a.username, a.file_path]);
        if (reason) details.push(`${AGENT_SAYS}${reason}`);
    }
    if (where) details.push(`Page: ${where}`);
    return { kind, summary, details, code };
}

/** A one-line summary for browser yolo's record: the summary plus the agent's reason, if any. */
export function summaryWithReason(summary, details) {
    const said = Array.isArray(details) ? details.find((d) => typeof d === 'string' && d.startsWith(AGENT_SAYS)) : null;
    return said ? `${summary} ${said}` : summary;
}
