/**
 * Minimal HTTP client for a local `opencode serve`.
 *
 * Covers what the Happy mirror needs: create/read sessions, post prompts
 * with our own message ids (so their echoes can be recognised), abort,
 * answer permissions and questions, read providers/agents for the app's pickers, and
 * follow the `/event` server-sent event stream with reconnects.
 *
 * Every request carries HTTP basic auth (`opencode` + the per-run password
 * Happy generated) and the working directory, which selects the project.
 */

import { randomBytes } from 'node:crypto';
import type { OpencodeEvent, OpencodePermissionReply, OpencodeQuestion } from './opencodeEventMapper';

export type OpencodeServerInfo = {
    url: string;
    password: string;
    directory: string;
};

export type OpencodeSessionInfo = {
    id: string;
    title?: string;
    parentID?: string;
    directory?: string;
};

export type OpencodeProviders = {
    providers: Array<{ id: string; name?: string; models: Record<string, { id?: string; name?: string }> }>;
    default: Record<string, string>;
};

export type OpencodeAgent = {
    name: string;
    description?: string;
    mode?: string;
    hidden?: boolean;
};

export type OpencodePromptInput = {
    text: string;
    messageId: string;
    model?: { providerID: string; modelID: string };
    agent?: string;
};

const BASE62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
let lastIdTimestamp = 0;
let idCounter = 0;

/**
 * A message id in OpenCode's own format (`msg_` + 12 hex digits of
 * time*4096+counter + 14 random base62 chars). OpenCode orders messages by
 * id, so ours must sort like the ones it generates.
 */
export function createOpencodeMessageId(now: number = Date.now()): string {
    if (now !== lastIdTimestamp) {
        lastIdTimestamp = now;
        idCounter = 0;
    }
    idCounter++;
    const value = (BigInt(now) * 4096n + BigInt(idCounter)) % (1n << 48n);
    const hex = value.toString(16).padStart(12, '0');
    const random = Array.from(randomBytes(14), (byte) => BASE62[byte % 62]).join('');
    return `msg_${hex}${random}`;
}

export class OpencodeHttpError extends Error {
    constructor(readonly status: number, message: string) {
        super(message);
    }
}

export class OpencodeClient {
    private readonly authorization: string;

    constructor(private readonly server: OpencodeServerInfo) {
        this.authorization = `Basic ${Buffer.from(`opencode:${server.password}`).toString('base64')}`;
    }

    private endpoint(path: string): string {
        const url = new URL(path, this.server.url);
        url.searchParams.set('directory', this.server.directory);
        return url.toString();
    }

    private async request<T>(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
        const response = await fetch(this.endpoint(path), {
            method,
            headers: {
                authorization: this.authorization,
                ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
            },
            body: body !== undefined ? JSON.stringify(body) : undefined,
            signal: signal ?? AbortSignal.timeout(15_000),
        });
        if (!response.ok) {
            const detail = await response.text().catch(() => '');
            throw new OpencodeHttpError(response.status, `${method} ${path} failed: ${response.status} ${detail.slice(0, 300)}`);
        }
        const text = await response.text();
        return (text ? JSON.parse(text) : undefined) as T;
    }

    createSession(title?: string): Promise<OpencodeSessionInfo> {
        return this.request('POST', '/session', title ? { title } : {});
    }

    getSession(id: string): Promise<OpencodeSessionInfo> {
        return this.request('GET', `/session/${encodeURIComponent(id)}`);
    }

    async promptAsync(sessionId: string, prompt: OpencodePromptInput): Promise<void> {
        await this.request('POST', `/session/${encodeURIComponent(sessionId)}/prompt_async`, {
            messageID: prompt.messageId,
            ...(prompt.model ? { model: prompt.model } : {}),
            ...(prompt.agent ? { agent: prompt.agent } : {}),
            parts: [{ type: 'text', text: prompt.text }],
        });
    }

    async abort(sessionId: string): Promise<void> {
        await this.request('POST', `/session/${encodeURIComponent(sessionId)}/abort`);
    }

    async replyPermission(requestId: string, reply: OpencodePermissionReply, message?: string): Promise<void> {
        await this.request('POST', `/permission/${encodeURIComponent(requestId)}/reply`, {
            reply,
            ...(message ? { message } : {}),
        });
    }

    listPermissions(): Promise<Array<{ id: string; sessionID: string; permission: string; patterns?: string[]; metadata?: Record<string, unknown> }>> {
        return this.request('GET', '/permission');
    }

    /** Questions the `question` tool is waiting on, across sessions of this server. */
    listQuestions(): Promise<Array<{ id: string; sessionID: string; questions: OpencodeQuestion[]; tool?: { messageID: string; callID: string } }>> {
        return this.request('GET', '/question');
    }

    /** Answer a question request: one list of chosen labels / typed text per question, in order. */
    async replyQuestion(requestId: string, answers: string[][]): Promise<void> {
        await this.request('POST', `/question/${encodeURIComponent(requestId)}/reply`, { answers });
    }

    /** Dismiss a question request; the tool fails with "The user dismissed this question". */
    async rejectQuestion(requestId: string): Promise<void> {
        await this.request('POST', `/question/${encodeURIComponent(requestId)}/reject`);
    }

    providers(): Promise<OpencodeProviders> {
        return this.request('GET', '/config/providers');
    }

    /** Effective configuration; only the fields Happy reads are typed. */
    config(): Promise<{ model?: string; default_agent?: string }> {
        return this.request('GET', '/config');
    }

    agents(): Promise<OpencodeAgent[]> {
        return this.request('GET', '/agent');
    }

    /** Liveness probe: true when the server answers authenticated requests. */
    async healthy(): Promise<boolean> {
        try {
            await this.request('GET', '/agent', undefined, AbortSignal.timeout(3_000));
            return true;
        } catch {
            return false;
        }
    }

    /**
     * Follow `/event` until `signal` aborts, reconnecting after drops.
     * `onConnected` runs on every (re)connect so the caller can resync state
     * that changed while the stream was down.
     */
    async streamEvents(opts: {
        signal: AbortSignal;
        onEvent: (event: OpencodeEvent) => void;
        onConnected?: () => void;
        onError?: (error: unknown) => void;
    }): Promise<void> {
        let delay = 250;
        while (!opts.signal.aborted) {
            try {
                const response = await fetch(this.endpoint('/event'), {
                    headers: { authorization: this.authorization, accept: 'text/event-stream' },
                    signal: opts.signal,
                });
                if (!response.ok || !response.body) {
                    throw new OpencodeHttpError(response.status, `GET /event failed: ${response.status}`);
                }
                delay = 250;
                opts.onConnected?.();
                await readServerSentEvents(response.body, opts.onEvent);
            } catch (error) {
                if (opts.signal.aborted) {
                    return;
                }
                opts.onError?.(error);
            }
            await new Promise<void>((resolve) => {
                const timer = setTimeout(resolve, delay);
                opts.signal.addEventListener('abort', () => {
                    clearTimeout(timer);
                    resolve();
                }, { once: true });
            });
            delay = Math.min(delay * 2, 5_000);
        }
    }
}

/** Parse a `text/event-stream` body, calling `onEvent` for each JSON `data:` payload. */
export async function readServerSentEvents(
    body: ReadableStream<Uint8Array>,
    onEvent: (event: OpencodeEvent) => void,
): Promise<void> {
    const decoder = new TextDecoder();
    let buffer = '';
    const dispatch = (block: string) => {
        const data = block
            .split('\n')
            .filter((line) => line.startsWith('data:'))
            .map((line) => line.slice(5).replace(/^ /, ''))
            .join('\n');
        if (!data) {
            return;
        }
        try {
            onEvent(JSON.parse(data) as OpencodeEvent);
        } catch {
            // Not JSON (should not happen with opencode); skip it.
        }
    };
    for await (const chunk of body as unknown as AsyncIterable<Uint8Array>) {
        buffer += decoder.decode(chunk, { stream: true }).replace(/\r\n/g, '\n');
        let boundary = buffer.indexOf('\n\n');
        while (boundary !== -1) {
            dispatch(buffer.slice(0, boundary));
            buffer = buffer.slice(boundary + 2);
            boundary = buffer.indexOf('\n\n');
        }
    }
    dispatch(buffer);
}
