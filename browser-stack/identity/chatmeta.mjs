// The chat a tool call comes from, as the Macs' gateway client names it (client/mcp-gateway-client.mjs).
//
// Behind the LAN gateway, agentgateway starts this stack's stdio MCP servers itself, one for many
// chats, so the process environment says nothing about the chat. The client on the Mac stamps
// every tools/call with _meta["browserstack/chat"] = {source, id, forked_from?}, from the
// harness's own environment (HAPPY_SESSION_ID, CLAUDE_CODE_SESSION_ID, BROWSER_CHAT_ID) or, for
// Happy Agent, from that Mac's agent database. Only an authenticated Mac reaches the gateway
// (its own key, from its own address), and the ids are the harnesses' unguessable session ids.
//
// A server reads this _meta only when its operator started it with BROWSER_CHAT_FROM_META=1
// (only the gateway's stdio env sets that). Otherwise the key is ignored, so a client that
// forges it gets nothing. Never from tool arguments: the model writes those.
export const CHAT_META_KEY = 'browserstack/chat';
const ID = /^[A-Za-z0-9_-]{1,128}$/;
// happy: a Happy session (the key the app computes); claude: a Claude Code session; agent: a
// Happy Agent agent without a Happy session; chat: any other harness's own chat id.
export const CHAT_SOURCES = Object.freeze(['happy', 'claude', 'agent', 'chat']);

/** Whether this process takes each call's chat from _meta (the operator's env, never a call). */
export const chatFromMeta = (env = process.env) => env.BROWSER_CHAT_FROM_META === '1';

/** {source, id, forkedFrom?} from a call's _meta, or null when it is missing or malformed. */
export function chatOfMeta(meta) {
    const c = meta && typeof meta === 'object' && !Array.isArray(meta) ? meta[CHAT_META_KEY] : undefined;
    if (!c || typeof c !== 'object' || Array.isArray(c)) return null;
    if (!CHAT_SOURCES.includes(c.source) || typeof c.id !== 'string' || !ID.test(c.id)) return null;
    const out = { source: c.source, id: c.id };
    // A fork's parent: a Happy session only, never the chat itself.
    if (c.source === 'happy' && typeof c.forked_from === 'string' && ID.test(c.forked_from) && c.forked_from !== c.id) out.forkedFrom = c.forked_from;
    return out;
}

/** The _meta passed on to anything downstream: without our key. */
export function withoutChatMeta(meta) {
    if (!meta || typeof meta !== 'object' || !(CHAT_META_KEY in meta)) return meta;
    const { [CHAT_META_KEY]: _drop, ...rest } = meta;
    return rest;
}

/** The secret filler's X-Happy-Chat for a call's chat: the Happy session id, else null ("none"). */
export const fillerChatOf = (c) => (c && c.source === 'happy' ? c.id : null);
