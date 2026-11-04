import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { configuration } from '@/configuration';

/**
 * The name of the Happy Agent that shares this Happy home, from its
 * `agent/runtime.toml` (`[node] name`). The app pairs with that agent
 * directly, by the same name, so publishing it in the machine's metadata
 * lets the app send a relay chat's links through the computer the chat runs
 * on. Null when no Happy Agent lives here or it has no name.
 */
export function readHappyAgentNodeName(happyHomeDir: string = configuration.happyHomeDir): string | null {
    let text: string;
    try {
        text = readFileSync(join(happyHomeDir, 'agent', 'runtime.toml'), 'utf8');
    } catch {
        return null;
    }
    return parseNodeName(text);
}

/** `[node] name` from a runtime.toml: a basic ("...") or literal ('...') string. */
export function parseNodeName(toml: string): string | null {
    let inNode = false;
    for (const raw of toml.split(/\r?\n/)) {
        const line = raw.trim();
        if (line.startsWith('[')) {
            inNode = line === '[node]';
            continue;
        }
        if (!inNode) continue;
        const basic = /^name\s*=\s*"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$/.exec(line);
        const literal = /^name\s*=\s*'([^']*)'\s*(?:#.*)?$/.exec(line);
        let value: string | null = null;
        if (basic) {
            try {
                value = JSON.parse(`"${basic[1]}"`);
            } catch {
                return null;
            }
        } else if (literal) {
            value = literal[1];
        }
        if (value === null) continue;
        const name = value.trim();
        return name.length > 0 ? name : null;
    }
    return null;
}
