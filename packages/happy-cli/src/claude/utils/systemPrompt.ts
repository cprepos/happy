import { trimIdent } from "@/utils/trimIdent";

/**
 * System prompt appended to every Claude session started by the CLI.
 * It deliberately says nothing about commit messages: commit attribution is
 * left to Claude Code's own settings.
 */
export const systemPrompt = (() => trimIdent(`
    ALWAYS when you start a new chat - you must call a tool "mcp__happy__change_title" to set a chat title. When you think chat title is not relevant anymore - call the tool again to change it. When chat name is too generic and you have a change to make it more specific - call the tool again to change it. This title is needed to easily find the chat in the future. Help human.
`))();
