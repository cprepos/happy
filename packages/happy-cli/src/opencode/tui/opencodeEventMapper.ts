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

/** One question of an OpenCode `question` tool call (OpenCode 1.19 `Question.Info`). */
export type OpencodeQuestion = {
    question: string;
    header: string;
    options: Array<{ label: string; description?: string }>;
    multiple?: boolean;
    /** Whether a typed answer is allowed; OpenCode treats a missing value as true. */
    custom?: boolean;
};

export type OpencodeMirrorAction =
    | { type: 'envelopes'; envelopes: SessionEnvelope[] }
    /** The followed session started working. */
    | { type: 'busy' }
    /** The followed session finished working (turn over). */
    | { type: 'idle' }
    /** `toolCallId` is the call id the tool-call envelopes use, so the app can join them. */
    | { type: 'permission-asked'; id: string; toolName: string; input: Record<string, unknown>; toolCallId?: string }
    | { type: 'permission-replied'; id: string; reply: OpencodePermissionReply }
    /**
     * The `question` tool is waiting for the user. `toolCallId` is set only
     * for questions of the followed session, whose tool call the app shows;
     * a sub-agent's question has no card to join.
     */
    | { type: 'question-asked'; id: string; questions: OpencodeQuestion[]; toolCallId?: string }
    /** Answered (from the TUI, or our own reply echoed back) or dismissed. `answers` is per question, in order. */
    | { type: 'question-resolved'; id: string; status: 'answered' | 'cancelled'; answers?: string[][] }
    | { type: 'title'; title: string }
    /** The TUI moved to another top-level session; the mirror follows it. */
    | { type: 'session-changed'; sessionId: string }
    /**
     * A one-line session event for the app's chat (`sendSessionEvent`
     * `message`). Compaction uses the Claude path's exact texts, so the app
     * renders it the same way and resets its context gauge.
     */
    | { type: 'event'; message: string };

/** The texts the Claude path sends around a compaction; the app keys on the second. */
export const COMPACTION_STARTED_EVENT = 'Compaction started';
export const COMPACTION_COMPLETED_EVENT = 'Compaction completed';

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

/**
 * Use OpenCode's own call id on tool envelopes instead of the generated one.
 * The app joins a permission request to its tool call by that id
 * (`toolUseId`), and OpenCode reports it on both the tool part and the
 * permission request.
 */
function withCallId(envelopes: SessionEnvelope[], callId: string): SessionEnvelope[] {
    return envelopes.map((envelope) => (
        envelope.ev.t === 'tool-call-start' || envelope.ev.t === 'tool-call-end'
            ? { ...envelope, ev: { ...envelope.ev, call: callId } }
            : envelope
    ));
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

    /**
     * Compaction. When the model's context fills up, OpenCode reports a
     * `ContextOverflowError` on `session.error`, but it does not fail the
     * turn: it adds a user message with a `compaction` part, streams a
     * summary as an assistant message (`mode: "compaction"`, `summary: true`),
     * re-posts the prompt that overflowed and publishes `session.compacted`.
     * The session stays busy throughout. None of that is the user's
     * conversation, so the mirror shows two event lines instead.
     */
    private readonly compactionParts = new Set<string>();
    private readonly summaryMessages = new Set<string>();
    private compacting = false;
    /** An overflow error held back until it is clear OpenCode will not compact it away. */
    private pendingOverflow: string | null = null;
    /** OpenCode re-posts the overflowed prompt after an overflow compaction; that copy is not a new prompt. */
    private replayExpected = false;
    /** Text of the latest user prompt (ours or the TUI's), to recognise that re-post. */
    private lastUserText: string | null = null;

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

    /**
     * Forward the finished paragraphs of the text or reasoning streaming
     * right now. The runner calls this on a timer: the app cannot grow a
     * message in place, so text otherwise reaches it only when the part ends
     * (a tool call, the switch from reasoning to text, or the end of the turn).
     */
    flushStreamingText(): OpencodeMirrorAction[] {
        if (!this.turnOpen) {
            return [];
        }
        return this.envelopes(this.manager.flushCompleteParagraphs());
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
            case 'session.compacted':
                return this.handleCompacted(props);
            case 'permission.asked':
                return this.handlePermissionAsked(props);
            case 'permission.replied':
                if (!this.isFollowedSession(props.sessionID) || typeof props.requestID !== 'string') return [];
                return [{ type: 'permission-replied', id: props.requestID, reply: props.reply }];
            case 'question.asked':
                return this.handleQuestionAsked(props);
            // Resolutions are not filtered by session: the runner only acts on
            // ids it is showing, and a question of a session the TUI moved
            // away from must still close in the app.
            case 'question.replied':
                if (typeof props.requestID !== 'string') return [];
                return [{
                    type: 'question-resolved',
                    id: props.requestID,
                    status: 'answered',
                    ...(Array.isArray(props.answers) ? { answers: props.answers } : {}),
                }];
            case 'question.rejected':
                if (typeof props.requestID !== 'string') return [];
                return [{ type: 'question-resolved', id: props.requestID, status: 'cancelled' }];
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
        const actions: OpencodeMirrorAction[] = [];
        if (this.pendingOverflow !== null) {
            // Nothing compacted it away (auto compaction is off, or the
            // compaction itself overflowed): it is a real error after all.
            actions.push(...this.errorStatus(this.pendingOverflow));
        }
        this.pendingOverflow = null;
        this.compacting = false;
        this.replayExpected = false;
        actions.push(...this.envelopes(this.closeTurn(this.turnStatus)));
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
            this.compacting = false;
            this.pendingOverflow = null;
            this.replayExpected = false;
            this.currentSessionId = info.sessionID;
            actions.push({ type: 'session-changed', sessionId: info.sessionID });
        }
        if (!this.messageRoles.has(info.id)) {
            this.messageRoles.set(info.id, info.role);
        }
        if (info.role === 'assistant' && (info.mode === 'compaction' || info.summary === true)) {
            this.summaryMessages.add(info.id);
            if (info.error?.name === 'ContextOverflowError' && typeof info.error.data?.message === 'string') {
                // The compaction could not fit either; OpenCode stops here.
                this.pendingOverflow = info.error.data.message.trim() || this.pendingOverflow;
            }
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
        if (this.summaryMessages.has(part.messageID)) {
            return [];
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
        if (part.type === 'compaction') {
            return this.handleCompactionPart(part);
        }
        if (part.type !== 'text' || part.synthetic || part.ignored) {
            return [];
        }
        const text = (part.text ?? '').trim();
        if (!text || this.sentUserParts.has(part.id)) {
            return [];
        }
        this.sentUserParts.add(part.id);
        if (this.replayExpected && text === this.lastUserText) {
            this.replayExpected = false;
            return [];
        }
        this.lastUserText = text;
        if (this.ownMessageIds.has(part.messageID)) {
            return [];
        }
        return this.envelopes([
            ...this.closeTurn('completed'),
            createEnvelope('user', { t: 'text', text }),
        ]);
    }

    private handleDelta(props: any): OpencodeMirrorAction[] {
        if (props.sessionID !== this.currentSessionId || props.field !== 'text' || typeof props.delta !== 'string') {
            return [];
        }
        if (this.messageRoles.get(props.messageID) !== 'assistant' || this.summaryMessages.has(props.messageID)) {
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
            envelopes.push(...withCallId(this.manager.mapMessage({
                type: 'tool-call',
                toolName,
                args: normalizeOpencodeToolInput(part.state?.input),
                callId,
            }), callId));
        }
        if ((status === 'completed' || status === 'error') && !this.finishedTools.has(callId)) {
            this.finishedTools.add(callId);
            envelopes.push(...this.ensureTurn());
            envelopes.push(...withCallId(this.manager.mapMessage({
                type: 'tool-result',
                toolName,
                result: status === 'completed' ? part.state?.output : { error: part.state?.error },
                callId,
            }), callId));
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
        if (error.name === 'ContextOverflowError') {
            // OpenCode compacts and retries on its own unless auto compaction
            // is off; hold the error until the session goes idle without that.
            this.pendingOverflow = detail;
            return [];
        }
        return this.errorStatus(detail);
    }

    private errorStatus(detail: string): OpencodeMirrorAction[] {
        const envelopes = this.ensureTurn();
        envelopes.push(...this.manager.mapMessage({ type: 'status', status: 'error', detail }));
        this.turnStatus = 'failed';
        return this.envelopes(envelopes);
    }

    private handleCompactionPart(part: PartLike & { overflow?: boolean }): OpencodeMirrorAction[] {
        if (this.compactionParts.has(part.id)) {
            return [];
        }
        this.compactionParts.add(part.id);
        // The overflow is being dealt with; a later one is reported afresh.
        this.pendingOverflow = null;
        if (part.overflow === true) {
            this.replayExpected = true;
        }
        const actions = this.markBusy();
        // Text streamed before the compaction belongs above the event line.
        actions.push(...this.envelopes(this.manager.flushText()));
        if (!this.compacting) {
            this.compacting = true;
            actions.push({ type: 'event', message: COMPACTION_STARTED_EVENT });
        }
        return actions;
    }

    private handleCompacted(props: any): OpencodeMirrorAction[] {
        if (props.sessionID !== this.currentSessionId || !this.compacting) {
            return [];
        }
        this.compacting = false;
        this.replayExpected = false;
        return [{ type: 'event', message: COMPACTION_COMPLETED_EVENT }];
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
        const toolCallId = typeof props.tool?.callID === 'string' ? props.tool.callID : undefined;
        return [{
            type: 'permission-asked',
            id: props.id,
            toolName: opencodeToolKind(permission),
            input,
            ...(toolCallId ? { toolCallId } : {}),
        }];
    }

    private handleQuestionAsked(props: any): OpencodeMirrorAction[] {
        if (!this.isFollowedSession(props.sessionID) || typeof props.id !== 'string' || !Array.isArray(props.questions)) {
            return [];
        }
        const questions: OpencodeQuestion[] = props.questions
            .filter((q: any) => q && typeof q.question === 'string')
            .map((q: any) => ({
                question: q.question,
                header: typeof q.header === 'string' ? q.header : '',
                options: Array.isArray(q.options)
                    ? q.options
                        .filter((option: any) => option && typeof option.label === 'string')
                        .map((option: any) => ({
                            label: option.label,
                            ...(typeof option.description === 'string' ? { description: option.description } : {}),
                        }))
                    : [],
                ...(typeof q.multiple === 'boolean' ? { multiple: q.multiple } : {}),
                ...(typeof q.custom === 'boolean' ? { custom: q.custom } : {}),
            }));
        const toolCallId = props.sessionID === this.currentSessionId && typeof props.tool?.callID === 'string'
            ? props.tool.callID
            : undefined;
        return [{ type: 'question-asked', id: props.id, questions, ...(toolCallId ? { toolCallId } : {}) }];
    }
}
