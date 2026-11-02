/**
 * Retention for the CLI's per-process log files; the daemon runs it at start and once a day.
 */

import { readdirSync, statSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Deletes `.log` files in `logsDir` not written for longer than `maxAgeMs`, except `keep`.
 *
 * Every CLI process writes its own `<date-time>-pid-<pid>[-daemon].log` and nothing removed them,
 * so the folder only grew: one machine held 480 files and 381 MB after 8 days, 90 MB of it from
 * a single day. `keep` is the caller's own log, which an idle daemon may not have touched in that
 * long. Files that vanish or cannot be removed are skipped. Returns what was deleted.
 */
export function logsPrune(
  logsDir: string,
  { maxAgeMs, keep, now = Date.now() }: { maxAgeMs: number; keep?: string; now?: number },
): { files: number; bytes: number } {
  const deleted = { files: 0, bytes: 0 };
  let names: string[];
  try {
    names = readdirSync(logsDir).filter((name) => name.endsWith('.log'));
  } catch {
    return deleted;
  }
  for (const name of names) {
    const path = join(logsDir, name);
    try {
      const stats = statSync(path);
      if (path === keep || !stats.isFile() || now - stats.mtimeMs <= maxAgeMs) {
        continue;
      }
      unlinkSync(path);
      deleted.files++;
      deleted.bytes += stats.size;
    } catch {
      // gone already, or not ours to remove
    }
  }
  return deleted;
}
