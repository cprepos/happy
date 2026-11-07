// What the user sees of an auto-browser approval: a short, scrubbed summary built from the
// controller's approval record. Never the typed text, a field's value, a tool's arguments, a
// file path or a query string; the agent's own reason is shown with anything that looks like a
// secret masked.

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
        case 'click': return 'Click on the page';
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
 * {kind, summary, details[]} for an approval record. `pageUrl` is the link's last known page,
 * used when the record has no observation.
 */
export function approvalSummary(record, pageUrl = null) {
    const kind = KIND_LABEL[record?.kind] ? record.kind : 'write';
    const summary = `The agent wants to ${KIND_LABEL[kind]}.`;
    const details = [];
    const where = placeOf(record?.observation?.url) || placeOf(pageUrl);
    if (record?.origin === 'tool_call') {
        const tool = toolNameOf(record);
        details.push(TOOL_LABEL[tool] || (tool ? `Use the tool ${tool}` : 'Use a browser tool'));
    } else {
        const a = record?.action || {};
        details.push(actionLine(a));
        const reason = scrubReason(a.reason || record?.reason, [a.text, a.value, a.username, a.file_path]);
        if (reason) details.push(`Agent says: ${reason}`);
    }
    if (where) details.push(`Page: ${where}`);
    return { kind, summary, details };
}
