/**
 * `happy desktop install | uninstall | status`
 *
 * Installs Happy's Claude Code plugin (bundled in `claude-desktop-plugin/`),
 * which mirrors Claude desktop Code sessions into Happy and delivers phone
 * messages to them. The plugin is installed at user scope through the
 * `claude plugin` CLI, so the desktop app's bundled Claude Code loads it.
 * Design and contract: docs/plans/happyify-desktop-sync.md.
 */

import chalk from 'chalk';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { projectPath } from '@/projectPath';
import { checkIfDaemonRunningAndCleanupStaleState } from '@/daemon/controlClient';
import {
    HAPPY_DESKTOP_PLUGIN_ID,
    findClaudeDesktopApp,
    isClaudeDesktopRunning,
    isClaudePluginInstalled,
} from '@/utils/detectCLI';

/** Marketplace name declared in claude-desktop-plugin/.claude-plugin/marketplace.json. */
const MARKETPLACE_NAME = 'happy';

/** The phase 0 test plugin, which hooks the same events and must not run alongside ours. */
const SPIKE_PLUGIN_ID = 'happyify@happyify-local';

/** Absolute path of the bundled plugin marketplace. */
export const desktopPluginMarketplacePath = resolve(projectPath(), 'claude-desktop-plugin');

function claudePlugin(args: string[]): void {
    console.log(chalk.gray(`$ claude plugin ${args.join(' ')}`));
    execFileSync('claude', ['plugin', ...args], { stdio: 'inherit' });
}

export async function handleDesktopCommand(args: string[]): Promise<void> {
    const subcommand = args[0];

    switch (subcommand) {
        case 'install':
            claudePlugin(['marketplace', 'add', desktopPluginMarketplacePath]);
            claudePlugin(['install', HAPPY_DESKTOP_PLUGIN_ID]);
            if (isClaudePluginInstalled(SPIKE_PLUGIN_ID)) {
                claudePlugin(['uninstall', SPIKE_PLUGIN_ID]);
            }
            console.log(chalk.green('Happy plugin installed. Restart open Claude desktop sessions to load it.'));
            return;
        case 'uninstall':
            claudePlugin(['uninstall', HAPPY_DESKTOP_PLUGIN_ID]);
            claudePlugin(['marketplace', 'remove', MARKETPLACE_NAME]);
            console.log(chalk.green('Happy plugin uninstalled.'));
            return;
        case 'status': {
            const app = findClaudeDesktopApp();
            const mark = (ok: boolean): string => (ok ? chalk.green('yes') : chalk.red('no'));
            console.log(`Claude.app installed:  ${mark(app !== null)}${app ? chalk.gray(`  (${app})`) : ''}`);
            console.log(`Claude.app running:    ${mark(isClaudeDesktopRunning())}`);
            console.log(`Happy plugin:          ${mark(isClaudePluginInstalled(HAPPY_DESKTOP_PLUGIN_ID))}`);
            console.log(`Happy daemon running:  ${mark(await checkIfDaemonRunningAndCleanupStaleState())}`);
            return;
        }
        default:
            console.log(`
${chalk.bold('happy desktop')} - Claude desktop app integration

${chalk.bold('Usage:')}
  happy desktop install     Install Happy's plugin into Claude Code (user scope)
  happy desktop uninstall   Remove the plugin and its marketplace
  happy desktop status      Show Claude.app, plugin and daemon state
`);
    }
}
