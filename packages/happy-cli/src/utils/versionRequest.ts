/**
 * Whether these CLI arguments ask the default (agent) command for its version:
 * `happy --version`, `happy -v`, `happy claude --version`, or a version flag
 * mixed with other default-command flags.
 *
 * A version request must never authenticate, start the daemon or touch a
 * session: agents run `happy --version` from inside a session, and before this
 * check such a run could join the surrounding session and end it.
 */
export function isVersionRequest(args: readonly string[]): boolean {
    // A subcommand (`happy daemon ...`, `happy codex ...`) parses its own flags.
    if (args.length > 0 && args[0] !== 'claude' && !args[0].startsWith('-')) {
        return false;
    }
    const rest = args[0] === 'claude' ? args.slice(1) : args;
    const end = rest.indexOf('--');
    const flags = end === -1 ? rest : rest.slice(0, end);
    return flags.some((arg) => arg === '-v' || arg === '--version');
}
