/**
 * Claude desktop detection: installed_plugins.json parsing, read from a
 * throwaway CLAUDE_CONFIG_DIR on disk. Kept apart from detectCLI.test.ts,
 * which mocks fs and child_process.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HAPPY_DESKTOP_PLUGIN_ID, isClaudePluginInstalled } from './detectCLI';

describe('isClaudePluginInstalled', () => {
    let configDir: string;
    let previousConfigDir: string | undefined;

    const writeInstalled = (contents: string): void => {
        mkdirSync(join(configDir, 'plugins'), { recursive: true });
        writeFileSync(join(configDir, 'plugins', 'installed_plugins.json'), contents);
    };

    beforeEach(() => {
        configDir = mkdtempSync(join(tmpdir(), 'happy-claude-config-'));
        previousConfigDir = process.env.CLAUDE_CONFIG_DIR;
        process.env.CLAUDE_CONFIG_DIR = configDir;
    });

    afterEach(() => {
        if (previousConfigDir === undefined) {
            delete process.env.CLAUDE_CONFIG_DIR;
        } else {
            process.env.CLAUDE_CONFIG_DIR = previousConfigDir;
        }
        rmSync(configDir, { recursive: true, force: true });
    });

    it('finds happy@happy when it is listed', () => {
        writeInstalled(JSON.stringify({
            version: 2,
            plugins: {
                'swift-lsp@claude-plugins-official': [{ scope: 'user', version: '1.0.0' }],
                [HAPPY_DESKTOP_PLUGIN_ID]: [{ scope: 'user', installPath: '/x', version: '1.0.0' }],
            },
        }));
        expect(isClaudePluginInstalled(HAPPY_DESKTOP_PLUGIN_ID)).toBe(true);
        expect(isClaudePluginInstalled('happyify@happyify-local')).toBe(false);
    });

    it('is false when the plugin has no install entries', () => {
        writeInstalled(JSON.stringify({ version: 2, plugins: { [HAPPY_DESKTOP_PLUGIN_ID]: [] } }));
        expect(isClaudePluginInstalled(HAPPY_DESKTOP_PLUGIN_ID)).toBe(false);
    });

    it('is false when installed_plugins.json is missing', () => {
        expect(isClaudePluginInstalled(HAPPY_DESKTOP_PLUGIN_ID)).toBe(false);
    });

    it('is false when installed_plugins.json is not valid JSON', () => {
        writeInstalled('{ not json');
        expect(isClaudePluginInstalled(HAPPY_DESKTOP_PLUGIN_ID)).toBe(false);
    });
});
