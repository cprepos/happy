/**
 * OpenCode server events -> Happy session protocol.
 *
 * `opencode serve` publishes everything that happens in its sessions on
 * `GET /event` (server-sent events), no matter which client caused it: the
 * attached TUI, the Happy app (through our HTTP calls) or OpenCode itself.
 * This mapper turns that stream into the envelopes the app already renders
 * for the ACP path, so a session looks the same in the app whichever way
 * OpenCode was started.
 *
 * Pure and synchronous: no I/O, so it can be driven from recorded events in
 * tests. Envelope construction goes through `AcpSessionManager`, the same
 * text/tool/turn bookkeeping the ACP runner uses.
 */

import { createEnvelope, type SessionEnvelope } from '@slopus/happy-wire';
import { AcpSessionManager } from '@/agent/acp/AcpSessionManager';

export type OpencodeEvent = {
    type: string;
    properties?: any;
};

export type OpencodePermissionReply = 'once' | 'always' | 'reject';

export type OpencodeMirrorAction =
    | { type: 'envelopes'; envelopes: SessionEnvelope[] }
    /** The followed session started working. */
    | { type: 'busy' }
    /** The followed session finished working (turn over). */
    | { type: 'idle' }
    | { type: 'permission-asked'; id: string; toolName: string; input: Record<string, unknown> }
    | { type: 'permission-replied'; id: string; reply: OpencodePermissionReply }
    | { type: 'title'; title: string }
    /** The TUI moved to another top-level session; the mirror follows it. */
    | { type: 'session-changed'; sessionId: string };

/**
 * OpenCode tool ids -> the tool kinds OpenCode reports over ACP. The app has
 * renderers for these kinds, so a TUI session's tool calls look like an ACP
 * session's. Unknown tools keep their OpenCode name.
 */
const TOOL_KINDS: Record<string, string> = {
    bash: 'execute',
    edit: 'edit',
    write: 'edit',
    patch: 'edit',
    multiedit: 'edit',
    apply_patch: 'edit',
    read: 'read',
    list: 'search',
    grep: 'search',
    glob: 'search',
    codesearch: 'search',
    websearch: 'search',
};

export function opencodeToolKind(tool: string): string {
    return TOOL_KINDS[tool] ?? tool;
}

/**
 * Add the argument spellings the app's renderers read (`path`/`file_path`,
 * `oldText`/`newText`) next to OpenCode's own (`filePath`, `oldString`,
 * `newString`). The originals stay so nothing is lost.
 */
export function normalizeOpencodeToolInput(input: unknown): Record<string, unknown> {
    if (!input || typeof input !== 'object' || Array.isArray(input)) {
        return {};
    }
    const args: Record<string, unknown> = { ...(input as Record<string, unknown>) };
    const filePath = typeof args.filePath === 'string'
        ? args.filePath
        : (typeof args.filepath === 'string' ? args.filepath : undefined);
    if (filePath !== undefined) {
        if (args.path === undefined) args.path = filePath;
        if (args.file_path === undefined) args.file_path = filePath;
    }
    if (typeof args.oldString === 'string' && args.oldText === undefined) {
        args.oldText = args.oldString;
    }
    if (typeof args.newString === 'string' && args.newText === undefined) {
        args.newText = args.newString;
    }
    return args;
}

/** OpenCode's placeholder titles, which are not worth showing in the app. */
function isDefaultTitle(title: string): boolean {
    return /^(New|Child) session - /.test(title);
}

type PartLike = {
    id: string;
    messageID: string;
    sessionID: string;
    type: string;
    text?: string;
    synthetic?: boolean;
    ignored?: boolean;
    callID?: string;
    tool?: string;
    state?: { status?: string; input?: unknown; output?: unknown; error?: unknown; title?: string };
};

export class OpencodeEventMapper {
    private currentSessionId: string;
    private readonly manager = new AcpSessionManager();
    private turnOpen = false;
    private busy = false;
    private turnStatus: 'completed' | 'failed' | 'cancelled' = 'completed';
    private lastTitle: string | null = null;

    /** Messages Happy posted on the app's behalf; the app already shows them. */
    private readonly ownMessageIds = new Set<string>();
    private readonly messageRoles = new Map<string, 'user' | 'assistant'>();
    /** Parts seen before their message's role was known. */
    private readonly pendingParts = new Map<string, PartLike[]>();
    private readonly partKinds = new Map<string, string>();
    /** Characters of each text/reasoning part already forwarded. */
    private readonly emittedLength = new Map<string, number>();
    private readonly sentUserParts = new Set<string>();
    private readonly startedTools = new Set<string>();
    private readonly finishedTools = new Set<string>();
    /** Sub-agent (task) sessions: their permissions belong to the followed session. */
    private readonly childSessions = new Set<string>();

    constructor(sessionId: string) {
        this.currentSessionId = sessionId;
    }

    get sessionId(): string {
        return this.currentSessionId;
    }

    get isBusy(): boolean {
        return this.busy;
    }

    /** Record a message id Happy is about to post, so its echo is not mirrored back. */
    markOwnMessage(messageId: string): void {
        this.ownMessageIds.add(messageId);
    }

    /** Close any open turn (used on shutdown so the app does not show a spinner forever). */
    closeTurn(status: 'completed' | 'failed' | 'cancelled'): SessionEnvelope[] {
        if (!this.turnOpen) {
            return [];
        }
        this.turnOpen = false;
        return this.manager.endTurn(status);
    }

    handle(event: OpencodeEvent): OpencodeMirrorAction[] {
        const props = event.properties ?? {};
        switch (event.type) {
            case 'session.created':
            case 'session.updated':
                return this.handleSessionInfo(props.info);
            case 'message.updated':
                return this.handleMessageUpdated(props.info);
            case 'message.part.updated':
                return this.handlePart(props.part);
            case 'message.part.delta':
                return this.handleDelta(props);
            case 'session.status':
                if (props.sessionID !== this.currentSessionId) return [];
                if (props.status?.type === 'busy' || props.status?.type === 'retry') {
                    return this.markBusy();
                }
                if (props.status?.type === 'idle') {
                    return this.markIdle();
                }
                return [];
            case 'session.idle':
                if (props.sessionID !== this.currentSessionId) return [];
                return this.markIdle();
            case 'session.error':
                return this.handleError(props);
            case 'permission.asked':
                return this.handlePermissionAsked(props);
            case 'permission.replied':
                if (!this.isFollowedSession(props.sessionID) || typeof props.requestID !== 'string') return [];
                return [{ type: 'permission-replied', id: props.requestID, reply: props.reply }];
            default:
                return [];
        }
    }

    private isFollowedSession(sessionId: unknown): boolean {
        return sessionId === this.currentSessionId || (typeof sessionId === 'string' && this.childSessions.has(sessionId));
    }

    private envelopes(envelopes: SessionEnvelope[]): OpencodeMirrorAction[] {
        return envelopes.length > 0 ? [{ type: 'envelopes', envelopes }] : [];
    }

    private ensureTurn(): SessionEnvelope[] {
        if (this.turnOpen) {
            return [];
        }
        this.turnOpen = true;
        this.turnStatus = 'completed';
        return this.manager.startTurn();
    }

    private markBusy(): OpencodeMirrorAction[] {
        const actions = this.envelopes(this.ensureTurn());
        if (!this.busy) {
            this.busy = true;
            actions.push({ type: 'busy' });
        }
        return actions;
    }

    private markIdle(): OpencodeMirrorAction[] {
        const actions = this.envelopes(this.closeTurn(this.turnStatus));
        if (this.busy) {
            this.busy = false;
            actions.push({ type: 'idle' });
        }
        return actions;
    }

    private handleSessionInfo(info: any): OpencodeMirrorAction[] {
        if (!info || typeof info.id !== 'string') {
            return [];
        }
        if (typeof info.parentID === 'string') {
            this.childSessions.add(info.id);
            return [];
        }
        if (info.id !== this.currentSessionId || typeof info.title !== 'string') {
            return [];
        }
        if (isDefaultTitle(info.title) || info.title === this.lastTitle) {
            return [];
        }
        this.lastTitle = info.title;
        return [{ type: 'title', title: info.title }];
    }

    private handleMessageUpdated(info: any): OpencodeMirrorAction[] {
        if (!info || typeof info.id !== 'string' || (info.role !== 'user' && info.role !== 'assistant')) {
            return [];
        }
        const actions: OpencodeMirrorAction[] = [];
        if (info.sessionID !== this.currentSessionId) {
            // A prompt typed in the TUI into another top-level session means
            // the user switched sessions there; follow them.
            const switched = info.role === 'user'
                && typeof info.sessionID === 'string'
                && !this.childSessions.has(info.sessionID)
                && !this.ownMessageIds.has(info.id);
            if (!switched) {
                return [];
            }
            actions.push(...this.envelopes(this.closeTurn('completed')));
            this.busy = false;
            this.lastTitle = null;
            this.currentSessionId = info.sessionID;
            actions.push({ type: 'session-changed', sessionId: info.sessionID });
        }
        if (!this.messageRoles.has(info.id)) {
            this.messageRoles.set(info.id, info.role);
        }
        const pending = this.pendingParts.get(info.id);
        if (pending) {
            this.pendingParts.delete(info.id);
            for (const part of pending) {
                actions.push(...this.handlePart(part));
            }
        }
        return actions;
    }

    private handlePart(part: PartLike | undefined): OpencodeMirrorAction[] {
        if (!part || typeof part.id !== 'string' || part.sessionID !== this.currentSessionId) {
            return [];
        }
        this.partKinds.set(part.id, part.type);
        const role = this.messageRoles.get(part.messageID);
        if (!role) {
            const queued = (this.pendingParts.get(part.messageID) ?? []).filter((p) => p.id !== part.id);
            queued.push(part);
            this.pendingParts.set(part.messageID, queued);
            return [];
        }
        if (role === 'user') {
            return this.handleUserPart(part);
        }
        switch (part.type) {
            case 'text':
                return this.forwardText(part.id, part.text ?? '', 'output', true);
            case 'reasoning':
                return this.forwardText(part.id, part.text ?? '', 'thinking', true);
            case 'tool':
                return this.handleToolPart(part);
            default:
                return [];
        }
    }

    private handleUserPart(part: PartLike): OpencodeMirrorAction[] {
        if (this.ownMessageIds.has(part.messageID) || part.type !== 'text' || part.synthetic || part.ignored) {
            return [];
        }
        const text = (part.text ?? '').trim();
        if (!text || this.sentUserParts.has(part.id)) {
            return [];
        }
        this.sentUserParts.add(part.id);
        return this.envelopes([
            ...this.closeTurn('completed'),
            createEnvelope('user', { t: 'text', text }),
        ]);
    }

    private handleDelta(props: any): OpencodeMirrorAction[] {
        if (props.sessionID !== this.currentSessionId || props.field !== 'text' || typeof props.delta !== 'string') {
            return [];
        }
        if (this.messageRoles.get(props.messageID) !== 'assistant') {
            return [];
        }
        const kind = this.partKinds.get(props.partID);
        if (kind !== 'text' && kind !== 'reasoning') {
            return [];
        }
        const already = this.emittedLength.get(props.partID) ?? 0;
        return this.forwardText(props.partID, props.delta, kind === 'text' ? 'output' : 'thinking', false, already);
    }

    /**
     * Forward new text of a part. Deltas are appended; a full snapshot
     * (`isSnapshot`) only contributes what was not forwarded yet, so a part
     * that streamed and then arrived complete is never sent twice.
     */
    private forwardText(
        partId: string,
        text: string,
        kind: 'output' | 'thinking',
        isSnapshot: boolean,
        already: number = this.emittedLength.get(partId) ?? 0,
    ): OpencodeMirrorAction[] {
        const fresh = isSnapshot ? text.slice(already) : text;
        if (!fresh) {
            return [];
        }
        this.emittedLength.set(partId, already + fresh.length);
        const envelopes = this.ensureTurn();
        if (kind === 'output') {
            envelopes.push(...this.manager.mapMessage({ type: 'model-output', textDelta: fresh }));
        } else {
            envelopes.push(...this.manager.mapMessage({ type: 'event', name: 'thinking', payload: { text: fresh, streaming: true } }));
        }
        return this.envelopes(envelopes);
    }

    private handleToolPart(part: PartLike): OpencodeMirrorAction[] {
        const status = part.state?.status;
        const callId = part.callID ?? part.id;
        if (!status || status === 'pending') {
            return [];
        }
        const toolName = opencodeToolKind(part.tool ?? 'unknown');
        const envelopes: SessionEnvelope[] = [];
        if (!this.startedTools.has(callId)) {
            this.startedTools.add(callId);
            envelopes.push(...this.ensureTurn());
            envelopes.push(...this.manager.mapMessage({
                type: 'tool-call',
                toolName,
                args: normalizeOpencodeToolInput(part.state?.input),
                callId,
            }));
        }
        if ((status === 'completed' || status === 'error') && !this.finishedTools.has(callId)) {
            this.finishedTools.add(callId);
            envelopes.push(...this.ensureTurn());
            envelopes.push(...this.manager.mapMessage({
                type: 'tool-result',
                toolName,
                result: status === 'completed' ? part.state?.output : { error: part.state?.error },
                callId,
            }));
        }
        return this.envelopes(envelopes);
    }

    private handleError(props: any): OpencodeMirrorAction[] {
        if (props.sessionID !== undefined && props.sessionID !== this.currentSessionId) {
            return [];
        }
        const error = props.error ?? {};
        if (error.name === 'MessageAbortedError') {
            this.turnStatus = 'cancelled';
            return [];
        }
        const detail = typeof error.data?.message === 'string' && error.data.message.trim()
            ? error.data.message.trim()
            : (typeof error.name === 'string' ? error.name : 'Unknown OpenCode error');
        const envelopes = this.ensureTurn();
        envelopes.push(...this.manager.mapMessage({ type: 'status', status: 'error', detail }));
        this.turnStatus = 'failed';
        return this.envelopes(envelopes);
    }

    private handlePermissionAsked(props: any): OpencodeMirrorAction[] {
        if (!this.isFollowedSession(props.sessionID) || typeof props.id !== 'string') {
            return [];
        }
        const permission = typeof props.permission === 'string' ? props.permission : 'unknown';
        const metadata = props.metadata && typeof props.metadata === 'object' ? props.metadata : {};
        const input: Record<string, unknown> = {
            ...normalizeOpencodeToolInput(metadata),
            ...(Array.isArray(props.patterns) ? { patterns: props.patterns } : {}),
        };
        return [{ type: 'permission-asked', id: props.id, toolName: opencodeToolKind(permission), input }];
    }
}
