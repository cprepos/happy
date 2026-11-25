// browser_stage_upload's file reading (mcp.mjs), on the agent's host, as the agent's own user.
//
// The agent names files by path; this reads them itself, so nothing else (no docker, no root) ever
// copies a host file into a browser. Every file must:
// - resolve (realpath, symlinks in its directories followed) to inside one of the roots: the chat's
//   working directory or the system temp directory (where a scratch directory lives), and not be
//   a root itself;
// - have no part, below that root, that starts with "." (.env, .ssh, .git, .aws/credentials, ...),
//   in the path as given or as resolved, and no directory part named secret(s) or credential(s);
// - be a regular file, the name given not a symlink (opened with O_NOFOLLOW, and the opened file
//   checked to be the very file the realpath named: same device and inode);
// - be at most FILE_MAX bytes, and the call's files together at most CALL_MAX.
// Anything else refuses the whole call before a byte is sent anywhere. -> [{path, name, size,
// sha256, data}], name the file's basename made into one the controller takes.
import { constants, openSync, fstatSync, readSync, closeSync, lstatSync, realpathSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, relative, isAbsolute, sep, basename } from 'node:path';

export const FILE_MAX = 50 * 1024 * 1024;
export const CALL_MAX = 100 * 1024 * 1024;
export const PATHS_MAX = 10;
const SECRET_DIR = /^(secrets?|credentials?)$/i;

export class StageRefused extends Error {}

// The controller's name rule (controller-patch UPLOAD_NAME): [A-Za-z0-9._-], at most 128, no leading dot.
export function uploadName(file) {
    let n = basename(file).replace(/[^A-Za-z0-9._-]/g, '_').replace(/^[.]+/, '');
    if (!n) n = 'upload';
    if (n.length > 128) {
        const dot = n.lastIndexOf('.');
        const ext = dot > 0 && n.length - dot <= 16 ? n.slice(dot) : '';
        n = n.slice(0, 128 - ext.length) + ext;
    }
    return n;
}

// The parts of `p` below whichever root holds it, or null when no root does (or it is a root).
function under(p, roots) {
    for (const root of roots) {
        const rel = relative(root, p);
        if (rel && !rel.startsWith('..') && !isAbsolute(rel)) return rel.split(sep);
    }
    return null;
}

function checkParts(parts, shown) {
    if (parts.some((x) => x.startsWith('.'))) throw new StageRefused(`${shown}: a hidden file or one in a hidden directory (a part starts with ".") is never staged`);
    if (parts.slice(0, -1).some((x) => SECRET_DIR.test(x))) throw new StageRefused(`${shown}: a file in a secrets or credentials directory is never staged`);
}

export function readStageFiles(paths, { roots, cwd = process.cwd(), fileMax = FILE_MAX, callMax = CALL_MAX } = {}) {
    if (!Array.isArray(paths) || paths.length < 1 || paths.length > PATHS_MAX) throw new StageRefused(`paths must be a list of 1 to ${PATHS_MAX} file paths`);
    if (paths.some((p) => typeof p !== 'string' || !p || p.includes('\0'))) throw new StageRefused('every path must be a non-empty string');
    // The roots as they really are (a symlinked /tmp, a cwd reached through a link).
    const real = [];
    for (const r of roots || []) {
        try { real.push(realpathSync(r)); } catch {}
    }
    if (!real.length) throw new StageRefused('no directory to stage files from (the chat\'s working directory and the temp directory are both missing)');
    const lexRoots = [...new Set([...(roots || []).map((r) => resolve(r)), ...real])];
    const out = [];
    let total = 0;
    for (const given of paths) {
        const abs = resolve(cwd, given);
        // The path as written: inside a root (in its own spelling or the real one) and nothing hidden.
        const lexParts = under(abs, lexRoots);
        if (lexParts) checkParts(lexParts, given);
        let st;
        try { st = lstatSync(abs); } catch { throw new StageRefused(`${given}: no such file`); }
        if (st.isSymbolicLink()) throw new StageRefused(`${given}: a symlink is never staged; name the file itself`);
        if (!st.isFile()) throw new StageRefused(`${given}: not a regular file`);
        let rp;
        try { rp = realpathSync(abs); } catch { throw new StageRefused(`${given}: no such file`); }
        const parts = under(rp, real);
        if (!parts) throw new StageRefused(`${given}: outside this chat's working directory and the temp directory; only files there can be staged`);
        checkParts(parts, given);
        let fd;
        try {
            fd = openSync(rp, constants.O_RDONLY | constants.O_NOFOLLOW | (constants.O_NONBLOCK || 0));
        } catch (err) {
            throw new StageRefused(`${given}: cannot be opened (${err.code || err.message})`);
        }
        try {
            const fst = fstatSync(fd);
            const now = statSync(rp);
            if (!fst.isFile()) throw new StageRefused(`${given}: not a regular file`);
            if (fst.dev !== now.dev || fst.ino !== now.ino || fst.dev !== st.dev || fst.ino !== st.ino) throw new StageRefused(`${given}: changed while it was being read; try again`);
            if (fst.size > fileMax) throw new StageRefused(`${given}: ${fst.size} bytes; a staged file may be at most ${fileMax}`);
            if (total + fst.size > callMax) throw new StageRefused(`the files together are over ${callMax} bytes; stage them in more than one call`);
            // Read to the end (and one byte past the limit, to catch a file that grew).
            const buf = Buffer.alloc(Math.min(fst.size, fileMax) + 1);
            let n = 0;
            for (;;) {
                const got = readSync(fd, buf, n, buf.length - n, null);
                if (!got) break;
                n += got;
                if (n === buf.length) break;
            }
            if (n > fileMax || n !== fst.size) throw new StageRefused(`${given}: changed while it was being read; try again`);
            const data = buf.subarray(0, n);
            total += n;
            out.push({ path: rp, name: uploadName(rp), size: n, sha256: createHash('sha256').update(data).digest('hex'), data });
        } finally {
            closeSync(fd);
        }
    }
    return out;
}
