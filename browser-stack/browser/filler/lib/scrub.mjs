// Replace typed secret values, in every encoding a page or tool result is likely
// to carry them, with "[secret:<name>]". Walks every string in a JSON payload
// (keys too), error messages included. Image content blocks can be dropped for
// sessions where a visible (non-password) secret was typed.

const MIN_CORE = 6; // shortest partial base64 run worth matching

function b64(buf) { return buf.toString('base64'); }
const urlSafe = (s) => s.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/** Base64 of v as it appears inside a longer base64 text, at each of the 3 byte alignments. */
function base64Variants(value) {
    const v = Buffer.from(value, 'utf8');
    const out = new Set();
    const full = b64(v);
    out.add(full);
    out.add(full.replace(/=+$/, ''));
    for (let k = 0; k < 3; k++) {
        const enc = b64(Buffer.concat([Buffer.alloc(k), v]));
        // Drop the group that holds filler bytes, and any group that holds bytes after v.
        const start = k ? 4 : 0;
        const end = Math.floor((k + v.length) / 3) * 4;
        const core = enc.slice(start, end);
        if (core.length >= MIN_CORE) out.add(core);
    }
    for (const s of [...out]) out.add(urlSafe(s));
    return [...out].filter(Boolean);
}

function htmlVariants(v) {
    const named = v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    return [named.replace(/'/g, '&#39;'), named.replace(/'/g, '&#x27;'), named.replace(/'/g, '&apos;')];
}

function formEncode(v) {
    return new URLSearchParams({ x: v }).toString().slice(2);
}

/** Every form of one value to look for, longest first. */
export function variantsOf(value) {
    const v = String(value);
    const out = new Set([v]);
    const uc = encodeURIComponent(v);
    out.add(uc);
    out.add(uc.replace(/%20/g, '+'));
    out.add(formEncode(v));
    out.add(encodeURI(v));
    const j1 = JSON.stringify(v).slice(1, -1);
    out.add(j1);
    out.add(JSON.stringify(j1).slice(1, -1));
    // JSON with every non-ASCII char \u-escaped (Python json.dumps default).
    out.add(j1.replace(/[\u0080-￿]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')));
    for (const h of htmlVariants(v)) out.add(h);
    for (const b of base64Variants(v)) out.add(b);
    return [...out].filter((s) => s.length > 0).sort((a, b) => b.length - a.length);
}

export function createScrubber() {
    // name -> Set(values); kept per scope (an auto-browser session id).
    const scopes = new Map();
    let compiled = null;

    function compile() {
        if (compiled) return compiled;
        const pairs = [];
        for (const entries of scopes.values()) for (const [value, name] of entries) for (const variant of variantsOf(value)) pairs.push([variant, name]);
        pairs.sort((a, b) => b[0].length - a[0].length);
        compiled = pairs;
        return pairs;
    }

    function scrubString(s) {
        if (typeof s !== 'string' || !s) return s;
        let out = s;
        for (const [variant, name] of compile()) if (out.includes(variant)) out = out.split(variant).join(`[secret:${name}]`);
        return out;
    }

    function walk(x, dropImages, depth = 0) {
        if (depth > 64) return '[scrubbed: too deep]';
        if (typeof x === 'string') return scrubString(x);
        if (Array.isArray(x)) return x.map((y) => walk(y, dropImages, depth + 1));
        if (x instanceof Error) return new Error(scrubString(x.message));
        if (x && typeof x === 'object') {
            if (dropImages && x.type === 'image' && typeof x.data === 'string') {
                return { type: 'text', text: '[image withheld: a secret was typed in this browser session and could be visible]' };
            }
            const o = {};
            for (const [k, v] of Object.entries(x)) {
                if (dropImages && typeof v === 'string' && /^(screenshot|image)(_base64|_data)?$/i.test(k) && v.length > 200) { o[k] = '[image withheld]'; continue; }
                o[scrubString(k)] = walk(v, dropImages, depth + 1);
            }
            return o;
        }
        return x;
    }

    return {
        /** Remember a value typed into scope (a browser session) under name. */
        add(scope, name, value) {
            if (typeof value !== 'string' || !value) return;
            if (!scopes.has(scope)) scopes.set(scope, new Map());
            scopes.get(scope).set(value, name);
            compiled = null;
        },
        drop(scope) { if (scopes.delete(scope)) compiled = null; },
        scopes: () => [...scopes.keys()],
        has: (scope) => scopes.has(scope),
        get size() { let n = 0; for (const m of scopes.values()) n += m.size; return n; },
        scrub: (payload, { dropImages = false } = {}) => walk(payload, dropImages),
        scrubString,
        /** Whether any remembered value, in any form, occurs in text (for leak sweeps). */
        leaks(text) { return compile().some(([variant]) => String(text).includes(variant)); },
    };
}
