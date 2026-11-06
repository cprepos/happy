import { describe, expect, it } from 'vitest';
import {
    getProcessStartTime,
    parseLinuxStatStartTime,
    parsePsLstart,
    type ProcessStartTimeDeps,
} from './processStartTime';

function statLine(comm: string, startTime: string): string {
    // pid (comm) state ppid pgrp session tty_nr tpgid flags minflt cminflt
    // majflt cmajflt utime stime cutime cstime priority nice num_threads
    // itrealvalue starttime ...
    const after = ['S', '1', '100', '100', '0', '-1', '4194560', '10', '0', '0', '0', '5', '3', '0', '0', '20', '0', '1', '0', startTime, '1000', '200'];
    return `4242 (${comm}) ${after.join(' ')}\n`;
}

describe('processStartTime', () => {
    it('parses the start time after a command name with spaces and parentheses', () => {
        expect(parseLinuxStatStartTime(statLine('a) (b c', '987654'))).toBe('987654');
        expect(parseLinuxStatStartTime(statLine('node', '12'))).toBe('12');
        expect(parseLinuxStatStartTime('garbage')).toBeUndefined();
    });

    it('builds a Linux identity from the boot id and the ticks', () => {
        const deps: ProcessStartTimeDeps = {
            platform: 'linux',
            readFile: (path) => path.endsWith('boot_id') ? 'boot-1\n' : statLine('a) (b c', '555'),
            runPs: () => { throw new Error('unused'); },
        };
        expect(getProcessStartTime(4242, deps)).toBe('linux:boot-1:555');
    });

    it('reports a missing Linux pid as null', () => {
        const deps: ProcessStartTimeDeps = {
            platform: 'linux',
            readFile: () => { throw Object.assign(new Error('gone'), { code: 'ENOENT' }); },
            runPs: () => '',
        };
        expect(getProcessStartTime(4242, deps)).toBeNull();
    });

    it('parses ps lstart output on macOS', () => {
        expect(parsePsLstart('Fri Nov  6 14:02:11 2026\n')).toBe('Fri Nov 6 14:02:11 2026');
        expect(parsePsLstart('  \n')).toBeNull();
        const deps: ProcessStartTimeDeps = {
            platform: 'darwin',
            readFile: () => '',
            runPs: () => 'Fri Nov  6 14:02:11 2026\n',
        };
        expect(getProcessStartTime(4242, deps)).toBe('darwin:Fri Nov 6 14:02:11 2026');
    });

    it('reports a missing macOS pid as null', () => {
        const empty: ProcessStartTimeDeps = { platform: 'darwin', readFile: () => '', runPs: () => '' };
        expect(getProcessStartTime(4242, empty)).toBeNull();
        const exit1: ProcessStartTimeDeps = {
            platform: 'darwin',
            readFile: () => '',
            runPs: () => { throw Object.assign(new Error('exit 1'), { status: 1 }); },
        };
        expect(getProcessStartTime(4242, exit1)).toBeNull();
    });

    it('is unknown on other platforms', () => {
        expect(getProcessStartTime(4242, { platform: 'win32', readFile: () => '', runPs: () => '' })).toBeUndefined();
    });

    it('is stable for this process', () => {
        const first = getProcessStartTime(process.pid);
        const second = getProcessStartTime(process.pid);
        expect(first).toBe(second);
        if (process.platform === 'linux' || process.platform === 'darwin') {
            expect(typeof first).toBe('string');
        }
    });
});
