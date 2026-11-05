// Append-only audit of fills: /filler/audit/YYYY-MM.jsonl, one line per fill
// attempt. Names, hosts and outcomes only; never a value. path says how the
// chat reached its client: mapped (its own entry in chats) or default. A fill
// allowed through equivalent domains has via "equivalent_domains" and
// equivalent_of, the saved host whose group granted the page's host.
import { appendFileSync, chmodSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const KEYS = ['ts', 'chat', 'client', 'path', 'session', 'name', 'host', 'field_kind', 'via', 'equivalent_of', 'outcome', 'step'];

export function createAudit(dir, { now = () => new Date() } = {}) {
    return {
        record(ev) {
            const d = now();
            const line = { ts: d.toISOString() };
            for (const k of KEYS.slice(1)) if (ev[k] !== undefined && ev[k] !== null) line[k] = String(ev[k]).slice(0, 200);
            const file = join(dir, `${d.toISOString().slice(0, 7)}.jsonl`);
            try {
                mkdirSync(dir, { recursive: true });
                appendFileSync(file, JSON.stringify(line) + '\n', { mode: 0o640 });
                chmodSync(file, 0o640);
            } catch (err) {
                process.stderr.write(`secret-filler: audit write failed: ${err.code || err.message}\n`);
            }
        },
    };
}
