/**
 * Retention for the CLI's per-process log files; the daemon runs it at start and once a day.
 */

import { readdirSync, statSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';

export type LogsPruneOptions = {
  /** Logs not written for longer than this are deleted. */
  maxAgeMs: number;
  /** After that, the oldest logs go until the folder is at most this big. */
  maxTotalBytes: number;
  /** Never deleted: the calling process's own log. */
  keep?: string;
  /** Logs written more recently than this are never deleted, since a live process may own them. */
  activeWindowMs?: number;
  now?: number;
};

/**
 * Deletes old `.log` files from the CLI's logs folder.
 *
 * Every CLI process writes its own `<date-time>-pid-<pid>[-daemon].log` and nothing removed them,
 * so the folder only grew: one machine held 480 files and 381 MB after 8 days, 90 MB of it from
 * a single day. First every log older than `maxAgeMs` goes, then the oldest remaining ones until
 * the total is within `maxTotalBytes`. The `keep` file and anything written in the last
 * `activeWindowMs` survive both passes, so a running session never loses the log it is writing,
 * even when that means the folder stays over the cap. Files that vanish or cannot be removed
 * are skipped. Returns how many files and bytes were deleted.
 */
export function logsPrune(logsDir: string, options: LogsPruneOptions): { files: number; bytes: number } {
  const now = options.now ?? Date.now();
  const activeWindowMs = options.activeWindowMs ?? 60 * 60 * 1000;
  const deleted = { files: 0, bytes: 0 };

  let names: string[];
  try {
    names = readdirSync(logsDir).filter((name) => name.endsWith('.log'));
  } catch {
    return deleted;
  }

  const logs: { path: string; size: number; mtimeMs: number }[] = [];
  for (const name of names) {
    const path = join(logsDir, name);
    try {
      const stats = statSync(path);
      if (stats.isFile()) {
        logs.push({ path, size: stats.size, mtimeMs: stats.mtimeMs });
      }
    } catch {
      // gone already
    }
  }
  logs.sort((a, b) => a.mtimeMs - b.mtimeMs);

  const removable = (log: { path: string; mtimeMs: number }) =>
    log.path !== options.keep && now - log.mtimeMs > activeWindowMs;
  const remove = (log: { path: string; size: number }) => {
    try {
      unlinkSync(log.path);
      deleted.files++;
      deleted.bytes += log.size;
      return true;
    } catch {
      return false;
    }
  };

  let total = logs.reduce((sum, log) => sum + log.size, 0);
  const remaining: typeof logs = [];
  for (const log of logs) {
    if (removable(log) && now - log.mtimeMs > options.maxAgeMs && remove(log)) {
      total -= log.size;
    } else {
      remaining.push(log);
    }
  }
  for (const log of remaining) {
    if (total <= options.maxTotalBytes) {
      break;
    }
    if (removable(log) && remove(log)) {
      total -= log.size;
    }
  }
  return deleted;
}
