// The 1Password service account token, read from its own file in the backend's
// secrets directory (secrets/<backend>/onepassword.token, mode 0400). Never from
// the environment, never from a symlink, never into a log or error message.
//
// The token ends up as a JS string (the SDK takes nothing else), and a JS string
// cannot be wiped. What this file can do: read through a Buffer it zeroes, hand
// the string to the caller once, and keep no copy. The caller passes it to
// createClient and drops it.
import { closeSync, constants, fstatSync, lstatSync, openSync, readSync } from 'node:fs';
import { join } from 'node:path';
import { ProviderError } from '../index.mjs';

export const DEFAULT_TOKEN_FILE = 'onepassword.token';
// A basename only: no separators, no dot files, no '..'.
const TOKEN_FILE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
// A service account token: "ops_" and base64 of a JSON document (about 1 KB).
const TOKEN = /^ops_[A-Za-z0-9+/=_-]{16,8000}$/;
const MAX_BYTES = 8192;

const notEnrolled = () => new ProviderError('1Password backend is not enrolled: no service account token file', 503);

/** The token file's path, or throws (a config error, never a value). */
export function tokenPath(secretsDir, tokenFile = DEFAULT_TOKEN_FILE) {
    if (typeof secretsDir !== 'string' || !secretsDir.startsWith('/')) throw new ProviderError('1Password backend: secretsDir must be an absolute path', 500);
    if (typeof tokenFile !== 'string' || !TOKEN_FILE.test(tokenFile) || tokenFile.includes('..')) throw new ProviderError('1Password backend: tokenFile must be a plain file name', 500);
    return join(secretsDir, tokenFile);
}

/**
 * Check, without reading it, that the token file is a regular file (not a
 * symlink) that only its owner can read. Throws 503 "not enrolled" when it is
 * missing, 500 when it is unsafe.
 */
export function checkTokenFile(path) {
    let st;
    try { st = lstatSync(path); } catch { throw notEnrolled(); }
    if (!st.isFile()) throw new ProviderError('1Password backend: the token file is not a regular file', 500);
    if (st.mode & 0o077) throw new ProviderError('1Password backend: the token file must be readable by its owner only (mode 0400)', 500);
    if (st.size === 0 || st.size > MAX_BYTES) throw new ProviderError('1Password backend: the token file has the wrong size', 500);
}

/** Read and check the token. The returned string is the only copy. */
export function readToken(path) {
    checkTokenFile(path);
    let fd;
    try { fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW); } catch { throw notEnrolled(); }
    const buf = Buffer.alloc(MAX_BYTES + 1);
    try {
        const st = fstatSync(fd);
        if (!st.isFile() || st.mode & 0o077) throw new ProviderError('1Password backend: the token file changed while it was read', 500);
        let n = 0;
        for (let r; n <= MAX_BYTES && (r = readSync(fd, buf, n, buf.length - n, null)) > 0;) n += r;
        if (n === 0 || n > MAX_BYTES) throw new ProviderError('1Password backend: the token file has the wrong size', 500);
        let end = n;
        while (end > 0 && (buf[end - 1] === 0x0a || buf[end - 1] === 0x0d || buf[end - 1] === 0x20)) end--;
        const token = buf.toString('latin1', 0, end);
        if (!TOKEN.test(token)) throw new ProviderError('1Password backend: the token file does not hold a service account token', 500);
        return token;
    } finally {
        buf.fill(0);
        closeSync(fd);
    }
}
