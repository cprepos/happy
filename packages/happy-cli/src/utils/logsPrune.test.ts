import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { existsSync, mkdtempSync, readdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { logsPrune } from './logsPrune';

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const NOW = Date.UTC(2026, 10, 2, 12);

describe('logsPrune', () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'happy-logs-'));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  function log(name: string, ageMs: number, size = 10): string {
    const path = join(dir, name);
    writeFileSync(path, 'x'.repeat(size));
    const t = (NOW - ageMs) / 1000;
    utimesSync(path, t, t);
    return path;
  }

  it('deletes logs older than the age limit and keeps newer ones', () => {
    log('old.log', 8 * DAY);
    log('new.log', 2 * DAY);
    const result = logsPrune(dir, { maxAgeMs: 7 * DAY, maxTotalBytes: Infinity, now: NOW });
    expect(readdirSync(dir)).toEqual(['new.log']);
    expect(result).toEqual({ files: 1, bytes: 10 });
  });

  it('deletes the oldest logs until the folder fits the size cap', () => {
    log('a.log', 5 * DAY, 100);
    log('b.log', 4 * DAY, 100);
    log('c.log', 3 * DAY, 100);
    logsPrune(dir, { maxAgeMs: 7 * DAY, maxTotalBytes: 150, now: NOW });
    expect(readdirSync(dir)).toEqual(['c.log']);
  });

  it('never deletes its own log or one written within the active window, even over the cap', () => {
    const own = log('own-daemon.log', 30 * DAY, 100);
    log('live.log', 10 * 60 * 1000, 100);
    log('stale.log', 2 * DAY, 100);
    logsPrune(dir, { maxAgeMs: 7 * DAY, maxTotalBytes: 0, keep: own, now: NOW });
    expect(readdirSync(dir).sort()).toEqual(['live.log', 'own-daemon.log']);
  });

  it('leaves files that are not logs alone', () => {
    log('notes.txt', 30 * DAY);
    logsPrune(dir, { maxAgeMs: DAY, maxTotalBytes: 0, now: NOW });
    expect(readdirSync(dir)).toEqual(['notes.txt']);
  });

  it('returns nothing deleted for a missing folder', () => {
    const missing = join(dir, 'missing');
    expect(logsPrune(missing, { maxAgeMs: DAY, maxTotalBytes: 0, now: NOW })).toEqual({ files: 0, bytes: 0 });
    expect(existsSync(missing)).toBe(false);
  });
});
