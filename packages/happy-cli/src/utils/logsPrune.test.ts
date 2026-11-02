import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { existsSync, mkdtempSync, readdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { logsPrune } from './logsPrune';

const DAY = 24 * 60 * 60 * 1000;
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
    log('new.log', 6 * DAY);
    const result = logsPrune(dir, { maxAgeMs: 7 * DAY, now: NOW });
    expect(readdirSync(dir)).toEqual(['new.log']);
    expect(result).toEqual({ files: 1, bytes: 10 });
  });

  it('never deletes its own log, however old', () => {
    const own = log('own-daemon.log', 30 * DAY);
    logsPrune(dir, { maxAgeMs: 7 * DAY, keep: own, now: NOW });
    expect(readdirSync(dir)).toEqual(['own-daemon.log']);
  });

  it('leaves files that are not logs alone', () => {
    log('notes.txt', 30 * DAY);
    logsPrune(dir, { maxAgeMs: 7 * DAY, now: NOW });
    expect(readdirSync(dir)).toEqual(['notes.txt']);
  });

  it('returns nothing deleted for a missing folder', () => {
    const missing = join(dir, 'missing');
    expect(logsPrune(missing, { maxAgeMs: 7 * DAY, now: NOW })).toEqual({ files: 0, bytes: 0 });
    expect(existsSync(missing)).toBe(false);
  });
});
