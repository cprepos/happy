/**
 * The environment a harness's agent process gets so the MCP servers it
 * starts (the browser bridge) know which Happy chat they serve, as
 * runClaude does for Claude. Empty while there is no Happy session yet
 * (offline start): the bridge then gives each browser a pod of its own.
 */
export function happySessionEnv(sessionId: string | null | undefined): Record<string, string> {
    return sessionId ? { HAPPY_SESSION_ID: sessionId } : {};
}
