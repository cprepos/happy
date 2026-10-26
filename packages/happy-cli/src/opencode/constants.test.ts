import { execSync } from 'node:child_process';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { findOpencodeBin, resolveOpencodeBin, OPENCODE_BIN } from './constants';

vi.mock('node:child_process', () => ({ execSync: vi.fn() }));

const mockedExecSync = vi.mocked(execSync);

describe('resolveOpencodeBin', () => {
  const orig = process.env.HAPPY_OPENCODE_PATH;

  beforeEach(() => {
    mockedExecSync.mockReset();
    mockedExecSync.mockReturnValue(Buffer.alloc(0));
  });

  afterEach(() => {
    if (orig === undefined) {
      delete process.env.HAPPY_OPENCODE_PATH;
    } else {
      process.env.HAPPY_OPENCODE_PATH = orig;
    }
  });

  it('uses HAPPY_OPENCODE_PATH when it points at an existing file', () => {
    process.env.HAPPY_OPENCODE_PATH = process.execPath;
    expect(findOpencodeBin()).toBe(process.execPath);
    expect(resolveOpencodeBin()).toBe(process.execPath);
  });

  it('ignores HAPPY_OPENCODE_PATH when the target does not exist', () => {
    process.env.HAPPY_OPENCODE_PATH = '/nonexistent/path/to/opencode-should-not-resolve';
    expect(resolveOpencodeBin()).not.toBe('/nonexistent/path/to/opencode-should-not-resolve');
  });

  it('spawns the bare name when opencode is on PATH', () => {
    delete process.env.HAPPY_OPENCODE_PATH;
    expect(resolveOpencodeBin()).toBe(OPENCODE_BIN);
    expect(mockedExecSync).toHaveBeenCalledWith(
      expect.stringMatching(/^(where|command -v) opencode$/),
      { stdio: 'ignore', windowsHide: true },
    );
  });

  it('never resolves to an empty command when the PATH probe fails', () => {
    delete process.env.HAPPY_OPENCODE_PATH;
    mockedExecSync.mockImplementation(() => {
      throw new Error('not found');
    });
    const resolved = resolveOpencodeBin();
    expect(resolved === OPENCODE_BIN || resolved.endsWith('/.opencode/bin/opencode')).toBe(true);
  });
});
