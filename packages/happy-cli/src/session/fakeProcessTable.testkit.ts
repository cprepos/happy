/**
 * An in-memory process table implementing `ProcessOps`, for tests of the
 * force-restart logic. Time is virtual: `sleep` advances the clock, and
 * processes react to signals the way their `onSignal` says.
 */

import type { ProcessOps } from './forceRestart';

export type FakeProcess = {
    pid: number;
    ppid?: number;
    pgid?: number;
    commandLine: string;
    startTimeMs: number;
    /** What a signal does; default: SIGKILL/SIGTERM/SIGUSR2 exit at once. */
    onSignal?: (signal: NodeJS.Signals, table: FakeProcessTable, pid: number) => void;
    /** Exit this many virtual ms after the first non-SIGKILL signal (instead of at once). */
    exitDelayMs?: number;
};

export class FakeProcessTable {
    processes = new Map<number, FakeProcess>();
    signals: Array<{ pid: number; signal: NodeJS.Signals }> = [];
    clock = 1_000_000_000_000;
    boot = this.clock - 3_600_000;
    pendingExits: Array<{ pid: number; at: number }> = [];
    selfPid = 1;

    add(process: FakeProcess): FakeProcess {
        this.processes.set(process.pid, { ppid: 1, pgid: process.pid, ...process });
        return process;
    }

    exit(pid: number): void {
        this.processes.delete(pid);
    }

    /** Ignore everything but SIGKILL (a wedged or SIGSTOPped process). */
    static ignoresSoftSignals(signal: NodeJS.Signals, table: FakeProcessTable, pid: number): void {
        if (signal === 'SIGKILL') {
            table.exit(pid);
        }
    }

    private deliver(pid: number, signal: NodeJS.Signals): void {
        const process = this.processes.get(pid);
        if (!process) {
            const error = new Error('kill ESRCH') as NodeJS.ErrnoException;
            error.code = 'ESRCH';
            throw error;
        }
        this.signals.push({ pid, signal });
        if (process.onSignal) {
            process.onSignal(signal, this, pid);
            return;
        }
        if (signal === 'SIGKILL' || process.exitDelayMs === undefined) {
            this.exit(pid);
            return;
        }
        if (!this.pendingExits.some((pending) => pending.pid === pid)) {
            this.pendingExits.push({ pid, at: this.clock + process.exitDelayMs });
        }
    }

    ops(): ProcessOps {
        return {
            isAlive: (pid) => this.processes.has(pid),
            commandLine: (pid) => this.processes.get(pid)?.commandLine ?? null,
            startTimeMs: (pid) => this.processes.get(pid)?.startTimeMs ?? null,
            parentPid: (pid) => this.processes.get(pid)?.ppid ?? null,
            processGroupId: (pid) => this.processes.get(pid)?.pgid ?? null,
            listPids: () => [...this.processes.keys()],
            kill: (pid, signal) => {
                if (pid < 0) {
                    const members = [...this.processes.values()].filter((process) => process.pgid === -pid);
                    if (members.length === 0) {
                        const error = new Error('kill ESRCH') as NodeJS.ErrnoException;
                        error.code = 'ESRCH';
                        throw error;
                    }
                    for (const member of members) {
                        this.deliver(member.pid, signal);
                    }
                    return;
                }
                this.deliver(pid, signal);
            },
            now: () => this.clock,
            sleep: async (ms) => {
                this.clock += ms;
                for (const pending of [...this.pendingExits]) {
                    if (pending.at <= this.clock) {
                        this.exit(pending.pid);
                        this.pendingExits.splice(this.pendingExits.indexOf(pending), 1);
                    }
                }
            },
            selfPid: this.selfPid,
            bootTimeMs: () => this.boot,
        };
    }
}
