import { describe, expect, it } from 'vitest';
import { selectOpencodeRoute } from './opencodeRoute';

const terminal = { forceAcp: false, headless: false, isTerminal: true, hasPassthroughArgs: false };

describe('selectOpencodeRoute', () => {
    it('gives a person at a terminal the TUI', () => {
        expect(selectOpencodeRoute(terminal)).toBe('tui');
        expect(selectOpencodeRoute({ ...terminal, startedBy: 'terminal' })).toBe('tui');
    });

    it('runs what the daemon starts, new or resumed, on the server route', () => {
        // The daemon's new-session spawn passes both flags, its resume only --started-by.
        expect(selectOpencodeRoute({ ...terminal, isTerminal: false, startedBy: 'daemon', startingMode: 'remote' })).toBe('headless');
        expect(selectOpencodeRoute({ ...terminal, isTerminal: false, startedBy: 'daemon' })).toBe('headless');
    });

    it('never opens a TUI for a daemon or remote start, even with a terminal inherited', () => {
        expect(selectOpencodeRoute({ ...terminal, startedBy: 'daemon' })).toBe('headless');
        expect(selectOpencodeRoute({ ...terminal, startingMode: 'remote' })).toBe('headless');
    });

    it('runs without a terminal on the server route', () => {
        expect(selectOpencodeRoute({ ...terminal, isTerminal: false })).toBe('headless');
    });

    it('honours --headless at a terminal, which is what --restart relies on', () => {
        expect(selectOpencodeRoute({ ...terminal, headless: true })).toBe('headless');
    });

    it('keeps ACP as an explicit escape hatch', () => {
        expect(selectOpencodeRoute({ ...terminal, forceAcp: true })).toBe('acp');
        expect(selectOpencodeRoute({ ...terminal, forceAcp: true, headless: true })).toBe('acp');
        expect(selectOpencodeRoute({ ...terminal, forceAcp: true, isTerminal: false, startedBy: 'daemon' })).toBe('acp');
    });

    it('keeps ACP when there are arguments for `opencode acp` and no terminal', () => {
        expect(selectOpencodeRoute({ ...terminal, isTerminal: false, hasPassthroughArgs: true })).toBe('acp');
    });
});
