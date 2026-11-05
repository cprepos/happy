// Random passwords for /v1/vault/create and rotate_password. Every new
// password is made here, from crypto.randomInt, and never leaves the filler
// except encrypted into the vault (or typed and piped like any other value).
// TOTP seeds are never generated: only the site's own setup can make one.
import { randomInt } from 'node:crypto';

export class GenerateError extends Error {
    constructor(message) { super(message); this.status = 400; }
}

export const CLASSES = Object.freeze({
    lower: 'abcdefghijklmnopqrstuvwxyz',
    upper: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    digits: '0123456789',
    symbols: '!#$%&()*+,-./:;<=>?@[]^_{|}~',
});
export const DEFAULT_SPEC = Object.freeze({ length: 32, classes: Object.freeze(['lower', 'upper', 'digits', 'symbols']), exclude: '' });
export const MIN_LENGTH = 16;
export const MAX_LENGTH = 128;

/** Check a generator spec ({length?, classes?, exclude?}); returns it with defaults filled in. */
export function checkSpec(spec = {}) {
    const { length, classes, exclude } = resolve(spec);
    return { length, classes, exclude };
}

function resolve(spec) {
    if (!spec || typeof spec !== 'object' || Array.isArray(spec)) throw new GenerateError('password must be an object {length?, classes?, exclude?}');
    const extra = Object.keys(spec).filter((k) => !['length', 'classes', 'exclude'].includes(k));
    if (extra.length) throw new GenerateError(`password: unknown key ${JSON.stringify(extra[0]).slice(0, 40)}`);
    const length = spec.length ?? DEFAULT_SPEC.length;
    if (!Number.isInteger(length) || length < MIN_LENGTH || length > MAX_LENGTH) throw new GenerateError(`password.length must be an integer ${MIN_LENGTH}..${MAX_LENGTH}`);
    const classes = spec.classes ?? DEFAULT_SPEC.classes;
    if (!Array.isArray(classes) || !classes.length || classes.some((c) => !Object.hasOwn(CLASSES, c)) || new Set(classes).size !== classes.length) {
        throw new GenerateError(`password.classes must be distinct names from ${Object.keys(CLASSES).join(', ')}`);
    }
    const exclude = spec.exclude ?? '';
    if (typeof exclude !== 'string' || exclude.length > 64) throw new GenerateError('password.exclude must be a string of at most 64 characters');
    const sets = classes.map((c) => [...CLASSES[c]].filter((ch) => !exclude.includes(ch)).join(''));
    const empty = sets.findIndex((s) => !s.length);
    if (empty >= 0) throw new GenerateError(`password.exclude removes every character of ${classes[empty]}`);
    if (classes.length > length) throw new GenerateError('password.length is shorter than the number of classes');
    return { length, classes: [...classes], exclude, sets };
}

/** A fresh random password: at least one character of each class, uniformly shuffled. */
export function generatePassword(spec = {}) {
    const { length, sets } = resolve(spec);
    const all = sets.join('');
    const chars = sets.map((s) => s[randomInt(s.length)]);
    while (chars.length < length) chars.push(all[randomInt(all.length)]);
    for (let i = chars.length - 1; i > 0; i--) { const j = randomInt(i + 1); [chars[i], chars[j]] = [chars[j], chars[i]]; }
    return chars.join('');
}
