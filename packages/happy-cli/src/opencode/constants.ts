/**
 * OpenCode Constants
 *
 * Binary resolution and fixed ACP arguments for the OpenCode integration.
 * OpenCode speaks the Agent Client Protocol through `opencode acp`, so the
 * session itself runs on the generic ACP runner (`src/agent/acp/runAcp.ts`);
 * this module only has to find the executable.
 */

import os from 'node:os';
import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { execSync } from 'node:child_process';

/** Default command name for the OpenCode binary (looked up on PATH). */
export const OPENCODE_BIN = 'opencode';

/** Arguments that put OpenCode into ACP server mode on stdio. */
export const OPENCODE_ACP_ARGS: readonly string[] = ['acp'];

/**
 * Find the installed OpenCode executable.
 *
 * The official installer puts OpenCode in `~/.opencode/bin` and adds that
 * directory to PATH through the user's shell rc file. A daemon started by
 * launchd/systemd or from a non-login shell never reads that file, so the bare
 * name fails with ENOENT even though OpenCode is installed. Resolution order:
 *   1. `HAPPY_OPENCODE_PATH` env override — an explicit absolute path.
 *   2. `opencode` already resolvable on PATH (then spawn the bare name).
 *   3. `~/.opencode/bin/opencode` — the installer's default location.
 */
export function findOpencodeBin(): string | undefined {
  const override = process.env.HAPPY_OPENCODE_PATH;
  if (override && existsSync(override)) {
    return override;
  }

  try {
    const probe = process.platform === 'win32'
      ? `where ${OPENCODE_BIN}`
      : `command -v ${OPENCODE_BIN}`;
    execSync(probe, { stdio: 'ignore', windowsHide: true });
    return OPENCODE_BIN;
  } catch {
    // not on PATH — fall through to the installer's location
  }

  const installerBin = join(
    os.homedir(),
    '.opencode',
    'bin',
    process.platform === 'win32' ? `${OPENCODE_BIN}.exe` : OPENCODE_BIN,
  );
  if (existsSync(installerBin)) {
    return installerBin;
  }

  return undefined;
}

/**
 * Resolve the OpenCode executable to a spawnable command.
 *
 * Falls back to the bare command name when nothing matches, so the caller still
 * spawns and surfaces a clear ENOENT instead of silently doing nothing.
 */
export function resolveOpencodeBin(): string {
  return findOpencodeBin() ?? OPENCODE_BIN;
}
