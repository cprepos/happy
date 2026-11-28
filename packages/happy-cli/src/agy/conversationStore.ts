/**
 * Agy conversation store
 *
 * agy records the most recent conversation per workspace in its cache file (keyed
 * by cwd). The backend pins the conversation agy's stream-json result names; this
 * cache is only its fallback, for a first turn stopped before that result.
 */

import { readFileSync, realpathSync } from 'node:fs';
import { AGY_CONVERSATIONS_CACHE } from './constants';

/**
 * Look up the agy conversation id recorded for `cwd`. Tries the path as given and
 * its realpath (macOS reports `/tmp/...` while the realpath is `/private/tmp/...`).
 * Returns null when the cache is missing/unreadable or has no entry for the cwd.
 */
export function readAgyConversationId(
  cwd: string,
  cachePath: string = AGY_CONVERSATIONS_CACHE,
): string | null {
  let raw: Record<string, string>;
  try {
    raw = JSON.parse(readFileSync(cachePath, 'utf-8')) as Record<string, string>;
  } catch {
    return null;
  }

  if (typeof raw[cwd] === 'string') {
    return raw[cwd];
  }

  try {
    const real = realpathSync(cwd);
    if (typeof raw[real] === 'string') {
      return raw[real];
    }
  } catch {
    /* ignore */
  }

  return null;
}
