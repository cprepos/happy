import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

/**
 * A stable identity for when a process started, so a recorded pid can be told
 * apart from a later process that reuses the same number.
 *
 * - a string: the start time, comparable only with another value from this
 *   function on the same machine;
 * - null: no process with this pid exists;
 * - undefined: the platform is not supported, or the start time could not be
 *   read for another reason (callers then fall back to the pid alone).
 */
export type ProcessStartTime = string | null | undefined;

export interface ProcessStartTimeDeps {
    platform: NodeJS.Platform;
    readFile: (path: string) => string;
    runPs: (pid: number) => string;
}

const defaultDeps: ProcessStartTimeDeps = {
    platform: process.platform,
    readFile: (path) => readFileSync(path, 'utf8'),
    runPs: (pid) => execFileSync('/bin/ps', ['-o', 'lstart=', '-p', String(pid)], {
        encoding: 'utf8',
        env: { LC_ALL: 'C', TZ: 'UTC' },
        timeout: 2000,
        stdio: ['ignore', 'pipe', 'ignore'],
        windowsHide: true,
    }),
};

/**
 * Field 22 (`starttime`, clock ticks since boot) of /proc/<pid>/stat. The
 * second field is the command name in parentheses and may itself contain
 * spaces and parentheses, so fields are counted from after the last `)`.
 */
export function parseLinuxStatStartTime(stat: string): string | undefined {
    const end = stat.lastIndexOf(')');
    if (end === -1) return undefined;
    const fields = stat.slice(end + 1).trim().split(/\s+/);
    // After the `)`: field 3 (state) is index 0, so field 22 is index 19.
    const startTime = fields[19];
    return startTime && /^\d+$/.test(startTime) ? startTime : undefined;
}

/** `ps -o lstart=` output, e.g. `Fri Nov  6 14:02:11 2026`; empty when the pid is gone. */
export function parsePsLstart(output: string): string | null {
    const trimmed = output.trim().replace(/\s+/g, ' ');
    return trimmed.length > 0 ? trimmed : null;
}

export function getProcessStartTime(pid: number, deps: ProcessStartTimeDeps = defaultDeps): ProcessStartTime {
    if (!Number.isSafeInteger(pid) || pid <= 0) return null;

    if (deps.platform === 'linux') {
        let stat: string;
        try {
            stat = deps.readFile(`/proc/${pid}/stat`);
        } catch (error) {
            return (error as NodeJS.ErrnoException).code === 'ENOENT' ? null : undefined;
        }
        const ticks = parseLinuxStatStartTime(stat);
        if (!ticks) return undefined;
        let bootId = 'unknown';
        try {
            bootId = deps.readFile('/proc/sys/kernel/random/boot_id').trim() || 'unknown';
        } catch {
            // Without a boot id the ticks are still unique within this boot.
        }
        return `linux:${bootId}:${ticks}`;
    }

    if (deps.platform === 'darwin') {
        let output: string;
        try {
            output = deps.runPs(pid);
        } catch (error) {
            // ps exits 1 when no such process exists.
            return (error as { status?: number }).status === 1 ? null : undefined;
        }
        const lstart = parsePsLstart(output);
        return lstart === null ? null : `darwin:${lstart}`;
    }

    return undefined;
}
