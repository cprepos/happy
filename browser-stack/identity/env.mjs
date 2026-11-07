// The chat a stdio MCP process serves, from the environment its harness started it with.
//
// - HAPPY_SESSION_ID: the Happy CLI gives each agent's MCP servers its Happy session (the chat).
//   HAPPY_FORKED_FROM_SESSION_ID names a forked chat's parent.
// - CLAUDE_CODE_SESSION_ID: Claude Code's own session.
// - BROWSER_CHAT_ID: any other harness that names its chat (generic; source "chat").
//
// Returns {source, id, forked_from?} in the _meta shape (chatmeta.mjs), or null. Read once at
// start from the process environment, never from a call, so the model can not choose a chat.
const ID = /^[A-Za-z0-9_-]{1,128}$/;

export function chatOfEnv(env = process.env) {
    const ok = (v) => typeof v === 'string' && ID.test(v);
    if (ok(env.HAPPY_SESSION_ID)) {
        const c = { source: 'happy', id: env.HAPPY_SESSION_ID };
        const parent = env.HAPPY_FORKED_FROM_SESSION_ID;
        if (ok(parent) && parent !== c.id) c.forked_from = parent;
        return c;
    }
    if (ok(env.CLAUDE_CODE_SESSION_ID)) return { source: 'claude', id: env.CLAUDE_CODE_SESSION_ID };
    if (ok(env.BROWSER_CHAT_ID)) return { source: 'chat', id: env.BROWSER_CHAT_ID };
    return null;
}
