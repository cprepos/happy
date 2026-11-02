import { describe, expect, it } from 'vitest';

import {
    getHarnessName,
    getSessionHarnessKey,
    HARNESS_NAMES,
    isClaudeDesktopSession,
    isRetiredHarness,
    listAvailableHarnesses,
} from './harnessCatalog';

describe('harness catalog', () => {
    it('names Happy and Antigravity by product, not by CLI id', () => {
        expect(HARNESS_NAMES.rig).toBe('Happy');
        expect(HARNESS_NAMES.agy).toBe('Antigravity');
    });

    it('retires Gemini only', () => {
        expect(isRetiredHarness('gemini')).toBe(true);
        expect(isRetiredHarness('claude')).toBe(false);
        // Antigravity is what Gemini's own error message redirects people to.
        expect(isRetiredHarness('agy')).toBe(false);
        expect(isRetiredHarness('openclaw')).toBe(false);
    });

    it('lists only installed harnesses, in pick order', () => {
        const harnesses = listAvailableHarnesses({
            availability: { claude: true, codex: true, agy: true },
            happyAgentAvailable: true,
            selected: 'claude',
        });

        expect(harnesses.map((harness) => harness.key)).toEqual(['claude', 'codex', 'agy', 'rig']);
        expect(harnesses.map((harness) => harness.name)).toEqual([
            'Claude Code',
            'Codex',
            'Antigravity',
            'Happy',
        ]);
    });

    it('never offers a retired harness, even with its CLI installed', () => {
        const harnesses = listAvailableHarnesses({
            availability: { claude: true, gemini: true },
            happyAgentAvailable: false,
            selected: 'claude',
        });

        expect(harnesses.map((harness) => harness.key)).toEqual(['claude']);
    });

    // The "keep the current selection listed" rule must not apply here, or a
    // stale draft would pin someone to an agent they can no longer start.
    it('does not keep a retired harness listed just because it is selected', () => {
        const harnesses = listAvailableHarnesses({
            availability: { claude: true, gemini: true },
            happyAgentAvailable: false,
            selected: 'gemini',
        });

        expect(harnesses.map((harness) => harness.key)).toEqual(['claude']);
    });

    it('keeps a real name for a retired harness so old sessions still read right', () => {
        expect(HARNESS_NAMES.gemini).toBe('Gemini');
    });

    // Only the machine running the gateway can start an OpenClaw session, so
    // the row has to wait for that machine's own installation report.
    it('lists OpenClaw only after an explicit installation report', () => {
        expect(HARNESS_NAMES.openclaw).toBe('OpenClaw');

        expect(listAvailableHarnesses({
            availability: { claude: true, codex: true, openclaw: true },
            happyAgentAvailable: false,
            selected: 'claude',
        }).map((harness) => harness.key)).toEqual(['claude', 'codex', 'openclaw']);

        expect(listAvailableHarnesses({
            availability: { claude: true, openclaw: false },
            happyAgentAvailable: false,
            selected: 'openclaw',
        }).map((harness) => harness.key)).toEqual(['claude']);

        expect(listAvailableHarnesses({
            availability: null,
            happyAgentAvailable: false,
            selected: 'openclaw',
        }).map((harness) => harness.key)).toEqual(['claude', 'codex']);
    });

    it('drops Happy when no connected machine can run it', () => {
        const harnesses = listAvailableHarnesses({
            availability: { claude: true, codex: true },
            happyAgentAvailable: false,
            selected: 'claude',
        });

        expect(harnesses.map((harness) => harness.key)).toEqual(['claude', 'codex']);
    });

    it('keeps the current selection listed even once its CLI disappears', () => {
        const harnesses = listAvailableHarnesses({
            availability: { claude: false, codex: true },
            happyAgentAvailable: false,
            selected: 'claude',
        });

        expect(harnesses.map((harness) => harness.key)).toEqual(['claude', 'codex']);
    });

    it('never lists Antigravity without an explicit installation report', () => {
        expect(listAvailableHarnesses({
            availability: { claude: true, agy: false },
            happyAgentAvailable: false,
            selected: 'agy',
        }).map((harness) => harness.key)).toEqual(['claude']);

        expect(listAvailableHarnesses({
            availability: null,
            happyAgentAvailable: false,
            selected: 'agy',
        }).map((harness) => harness.key)).toEqual(['claude', 'codex']);
    });

    it('lists OpenCode only after an explicit installation report', () => {
        expect(HARNESS_NAMES.opencode).toBe('OpenCode');

        expect(listAvailableHarnesses({
            availability: { claude: true, codex: true, agy: true, opencode: true },
            happyAgentAvailable: false,
            selected: 'claude',
        }).map((harness) => harness.key)).toEqual(['claude', 'codex', 'agy', 'opencode']);

        expect(listAvailableHarnesses({
            availability: { claude: true, opencode: false },
            happyAgentAvailable: false,
            selected: 'opencode',
        }).map((harness) => harness.key)).toEqual(['claude']);

        expect(listAvailableHarnesses({
            availability: null,
            happyAgentAvailable: false,
            selected: 'opencode',
        }).map((harness) => harness.key)).toEqual(['claude', 'codex']);
    });

    it('falls back to the whole catalog when a machine reports no capabilities', () => {
        expect(listAvailableHarnesses({
            availability: null,
            happyAgentAvailable: false,
            selected: null,
        }).map((harness) => harness.key)).toEqual(['claude', 'codex']);

        expect(listAvailableHarnesses({
            availability: {},
            happyAgentAvailable: false,
            selected: null,
        }).map((harness) => harness.key)).toEqual(['claude', 'codex', 'rig']);
    });
});

describe('Claude Desktop harness', () => {
    it('is named by product and sits directly after Claude Code', () => {
        expect(HARNESS_NAMES['claude-desktop']).toBe('Claude Desktop');
        expect(listAvailableHarnesses({
            availability: { claude: true, 'claude-desktop': true, codex: true },
            happyAgentAvailable: false,
            selected: 'claude',
        }).map((harness) => harness.key)).toEqual(['claude', 'claude-desktop', 'codex']);
    });

    // The daemon reports it only while the desktop app runs with the plugin,
    // so a missing or false report means there is nothing to start it in.
    it('is listed only on an explicit true report, never as a fallback or selection', () => {
        expect(listAvailableHarnesses({
            availability: { claude: true, codex: true },
            happyAgentAvailable: false,
            selected: 'claude-desktop',
        }).map((harness) => harness.key)).toEqual(['claude', 'codex']);

        expect(listAvailableHarnesses({
            availability: { claude: true, 'claude-desktop': false },
            happyAgentAvailable: false,
            selected: 'claude-desktop',
        }).map((harness) => harness.key)).toEqual(['claude']);

        expect(listAvailableHarnesses({
            availability: null,
            happyAgentAvailable: false,
            selected: null,
        }).map((harness) => harness.key)).not.toContain('claude-desktop');
    });

    it('labels a session by its harness before its flavor', () => {
        expect(getHarnessName(getSessionHarnessKey({ flavor: 'claude', harness: 'claude-desktop' }))).toBe('Claude Desktop');
        expect(getHarnessName(getSessionHarnessKey({ flavor: 'claude' }))).toBe('Claude Code');
        expect(getHarnessName(getSessionHarnessKey({ flavor: 'codex', harness: null }))).toBe('Codex');
        expect(getSessionHarnessKey(null)).toBe('claude');
    });

    it('recognises a desktop session only by metadata.harness', () => {
        expect(isClaudeDesktopSession({ harness: 'claude-desktop' })).toBe(true);
        expect(isClaudeDesktopSession({ harness: 'something-newer' })).toBe(false);
        expect(isClaudeDesktopSession({})).toBe(false);
        expect(isClaudeDesktopSession(null)).toBe(false);
    });
});
