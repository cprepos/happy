// Copy one token file across the account line, between happy-filler and the
// operator (prep), without root:
//
//   node scripts/handoff-copy.mjs <src> <dst> [--mode 0400|0600]
//
// The one helper the token make targets call, both ways: happy-filler's make
// filler-controller-token-take takes /srv/happy-filler/inbox/controller-token
// (dropped by prep's make filler-controller-token-give), and prep's make
// filler-token-take takes /srv/happy-filler/outbox/{bridge,vault}-client-token
// (written by happy-filler's make filler-token-issue). The source sits in a directory the other side
// can write, so it is opened without following a symlink and must be a regular
// file with one link, owned by someone other than the reader (a file of one's
// own there is a trick, not a handoff), at most 1 KiB, holding one token. The
// value is written to <dst> (created, never overwritten) and never printed.
import { closeSync, constants, fstatSync, openSync, readSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const TOKEN = /^[A-Za-z0-9._~+/=-]{16,512}$/;
const MAX = 1024;

export class HandoffError extends Error {}

/** The token in <path>, checked as above. selfUid: the reader's uid (tests inject it). */
export function readHandoff(path, { selfUid = process.getuid() } = {}) {
    let fd;
    try {
        fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    } catch (err) {
        throw new HandoffError(err.code === 'ELOOP' ? 'is a symlink' : err.code === 'ENOENT' ? 'missing' : `unreadable (${err.code})`);
    }
    try {
        const st = fstatSync(fd);
        if (!st.isFile()) throw new HandoffError('not a regular file');
        if (st.nlink !== 1) throw new HandoffError('has more than one link');
        if (st.uid === selfUid) throw new HandoffError('is owned by the reader, not the other side');
        if (st.size > MAX) throw new HandoffError('too large for a token');
        const buf = Buffer.alloc(MAX + 1);
        const n = readSync(fd, buf, 0, buf.length, 0);
        if (n > MAX) throw new HandoffError('too large for a token');
        const v = buf.subarray(0, n).toString('utf8').replace(/\r?\n$/, '');
        if (!TOKEN.test(v)) throw new HandoffError('does not hold a token');
        return v;
    } finally {
        closeSync(fd);
    }
}

export function copyHandoff(src, dst, { mode = 0o400, selfUid } = {}) {
    const v = readHandoff(src, selfUid === undefined ? {} : { selfUid });
    writeFileSync(dst, v, { mode, flag: 'wx' });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
    const [src, dst, flag, m] = process.argv.slice(2);
    const mode = flag === '--mode' ? Number.parseInt(m, 8) : 0o400;
    if (!src || !dst || (flag && flag !== '--mode') || ![0o400, 0o600].includes(mode)) {
        process.stderr.write('usage: node handoff-copy.mjs <src> <dst> [--mode 0400|0600]\n');
        process.exit(2);
    }
    try {
        copyHandoff(src, dst, { mode });
    } catch (err) {
        process.stderr.write(`handoff-copy: ${src}: ${err instanceof HandoffError ? err.message : (err.code || 'failed')}\n`);
        process.exit(1);
    }
}
