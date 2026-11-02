/**
 * Which runner a `happy opencode` invocation gets.
 *
 * - `tui`: a person at a terminal. The real OpenCode TUI on a local
 *   `opencode serve`, mirrored to the app.
 * - `headless`: nobody at a terminal, which includes every session the daemon
 *   starts for the app. The same `opencode serve` mirror without the TUI.
 * - `acp`: `opencode acp` on the generic ACP runner, now only on request.
 *
 * App-started sessions moved off ACP because OpenCode's ACP server cannot ask
 * questions: it leaves the `question` tool out unless
 * OPENCODE_ENABLE_QUESTION_TOOL is set (only the app, cli and desktop clients
 * get it by default), and even with the flag its event handler has no case for
 * `question.asked`, so a turn would wait on a form no client ever sees. The
 * server route has the question bridge and no turn timeout to outlast.
 */

export type OpencodeRoute = 'tui' | 'headless' | 'acp';

export function selectOpencodeRoute(input: {
    /** `--acp` or HAPPY_OPENCODE_MODE=acp. */
    forceAcp: boolean;
    /** `--headless`. */
    headless: boolean;
    startedBy?: 'daemon' | 'terminal';
    startingMode?: string;
    /** stdin and stdout are both a terminal. */
    isTerminal: boolean;
    /** Arguments after `--`, which are meant for `opencode acp`. */
    hasPassthroughArgs: boolean;
}): OpencodeRoute {
    if (input.forceAcp) {
        return 'acp';
    }
    if (input.headless) {
        return 'headless';
    }
    if (input.isTerminal && input.startedBy !== 'daemon' && input.startingMode !== 'remote') {
        return 'tui';
    }
    return input.hasPassthroughArgs ? 'acp' : 'headless';
}
