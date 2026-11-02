import { execSync } from 'child_process';
import os from 'os';
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { findAgyBin } from '@/agy/constants';
import { findOpencodeBin } from '@/opencode/constants';

export interface CLIAvailability {
  claude: boolean;
  codex: boolean;
  gemini: boolean;
  openclaw: boolean;
  agy: boolean;
  opencode: boolean;
  /** Claude Desktop is installed and running, with Happy's plugin installed. */
  'claude-desktop': boolean;
  detectedAt: number;
}

/**
 * Detects which CLI tools are available on this machine.
 * Cross-platform: uses `command -v` on POSIX, `Get-Command` on Windows.
 */
export function detectCLIAvailability(): CLIAvailability {
  const isWindows = os.platform() === 'win32';

  if (isWindows) {
    return detectWindows();
  }
  return detectPosix();
}

function commandExists(command: string): boolean {
  try {
    execSync(`command -v ${command} >/dev/null 2>&1`, { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function detectPosix(): CLIAvailability {
  const claude = commandExists('claude');
  const codex = commandExists('codex');
  const gemini = commandExists('gemini');
  const agy = findAgyBin() !== undefined;
  const opencode = findOpencodeBin() !== undefined;
  const claudeDesktop = detectClaudeDesktop();

  // OpenClaw: check command, config file, or env var
  const openclawCommand = commandExists('openclaw');
  const openclawConfig = existsSync(join(os.homedir(), '.openclaw', 'openclaw.json'));
  const openclawEnv = !!process.env.OPENCLAW_GATEWAY_URL;
  const openclaw = openclawCommand || openclawConfig || openclawEnv;

  return { claude, codex, gemini, openclaw, agy, opencode, 'claude-desktop': claudeDesktop, detectedAt: Date.now() };
}

function detectWindows(): CLIAvailability {
  const checkCommand = (name: string): boolean => {
    try {
      execSync(`powershell -NoProfile -Command "Get-Command ${name} -ErrorAction SilentlyContinue"`, { stdio: 'ignore', windowsHide: true });
      return true;
    } catch {
      return false;
    }
  };

  const claude = checkCommand('claude');
  const codex = checkCommand('codex');
  const gemini = checkCommand('gemini');
  const agy = findAgyBin() !== undefined;
  const opencode = findOpencodeBin() !== undefined;
  const claudeDesktop = detectClaudeDesktop();

  // OpenClaw: check command, config file, or env var
  const openclawCommand = checkCommand('openclaw');
  const openclawConfig = existsSync(join(process.env.USERPROFILE || os.homedir(), '.openclaw', 'openclaw.json'));
  const openclawEnv = !!process.env.OPENCLAW_GATEWAY_URL;
  const openclaw = openclawCommand || openclawConfig || openclawEnv;

  return { claude, codex, gemini, openclaw, agy, opencode, 'claude-desktop': claudeDesktop, detectedAt: Date.now() };
}

/** Plugin id of Happy's Claude desktop plugin (`<plugin>@<marketplace>`). */
export const HAPPY_DESKTOP_PLUGIN_ID = 'happy@happy';

/** Path of Claude.app in /Applications or ~/Applications, or null when it is not installed. */
export function findClaudeDesktopApp(): string | null {
  const candidates = ['/Applications/Claude.app', join(os.homedir(), 'Applications', 'Claude.app')];
  return candidates.find((candidate) => existsSync(candidate)) ?? null;
}

/** Whether the Claude desktop app's main process (named `Claude`) is running. */
export function isClaudeDesktopRunning(): boolean {
  try {
    execSync('pgrep -x Claude', { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

/**
 * Whether Claude Code lists `pluginId` in its installed_plugins.json, under
 * CLAUDE_CONFIG_DIR when set, else ~/.claude. A missing or unreadable file
 * means nothing is installed.
 */
export function isClaudePluginInstalled(pluginId: string): boolean {
  const configDir = process.env.CLAUDE_CONFIG_DIR || join(os.homedir(), '.claude');
  try {
    const installed = JSON.parse(readFileSync(join(configDir, 'plugins', 'installed_plugins.json'), 'utf8')) as {
      plugins?: Record<string, unknown>;
    };
    const entries = installed.plugins?.[pluginId];
    return Array.isArray(entries) && entries.length > 0;
  } catch {
    return false;
  }
}

/**
 * Claude Desktop as a harness: macOS only, Claude.app installed, its process
 * running, and Happy's plugin listed in installed_plugins.json.
 */
function detectClaudeDesktop(): boolean {
  return os.platform() === 'darwin'
    && findClaudeDesktopApp() !== null
    && isClaudeDesktopRunning()
    && isClaudePluginInstalled(HAPPY_DESKTOP_PLUGIN_ID);
}
