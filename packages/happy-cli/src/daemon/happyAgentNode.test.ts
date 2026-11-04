import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

import { parseNodeName, readHappyAgentNodeName } from './happyAgentNode';

describe('parseNodeName', () => {
    it('reads the name from the [node] table', () => {
        expect(parseNodeName('[skill_enablement]\n[node]\nname = "prep-pro"\n\n[providers.claude]\nauto_enable = true\n')).toBe('prep-pro');
    });

    it('keeps non-ASCII names and decodes escapes', () => {
        expect(parseNodeName('[node]\nname = "Christopher’s MacBook Pro"')).toBe('Christopher’s MacBook Pro');
        expect(parseNodeName('[node]\nname = "a\\"b \\u00e9"')).toBe('a"b é');
    });

    it('reads literal strings and ignores trailing comments', () => {
        expect(parseNodeName("[node]\nname = 'prep-ml' # set by hand")).toBe('prep-ml');
    });

    it('ignores a name outside [node]', () => {
        expect(parseNodeName('[providers.coder]\nname = "coder"\n[node]\navatar = "x"')).toBeNull();
    });

    it('treats a blank name as none', () => {
        expect(parseNodeName('[node]\nname = "   "')).toBeNull();
    });
});

describe('readHappyAgentNodeName', () => {
    it('reads agent/runtime.toml under the Happy home', () => {
        const home = mkdtempSync(join(tmpdir(), 'happy-home-'));
        mkdirSync(join(home, 'agent'));
        writeFileSync(join(home, 'agent', 'runtime.toml'), '[node]\nname = "prep-air"\n');
        expect(readHappyAgentNodeName(home)).toBe('prep-air');
    });

    it('is null when no Happy Agent lives there', () => {
        expect(readHappyAgentNodeName(mkdtempSync(join(tmpdir(), 'happy-home-')))).toBeNull();
    });
});
