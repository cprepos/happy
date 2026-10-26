import { describe, expect, it } from 'vitest';
import type { ApiSessionClient } from '@/api/apiSession';
import type { AgentState } from '@/api/types';
import { OpencodePermissionBridge, opencodeReplyForDecision } from './opencodePermissionBridge';
import type { OpencodePermissionReply } from './opencodeEventMapper';

type RpcHandler = (params: any) => Promise<unknown>;

/** Stands in for the session socket: keeps agent state and the registered RPC handlers. */
function fakeSession() {
    const handlers = new Map<string, RpcHandler>();
    let state: AgentState = {};
    const session = {
        rpcHandlerManager: {
            registerHandler: (method: string, handler: RpcHandler) => { handlers.set(method, handler); },
        },
        updateAgentState: (update: (current: AgentState) => AgentState) => { state = update(state); },
    };
    return {
        session: session as unknown as ApiSessionClient,
        state: () => state,
        callRpc: (method: string, params: unknown) => handlers.get(method)!(params),
    };
}

function setup() {
    const fake = fakeSession();
    const replies: Array<[string, OpencodePermissionReply]> = [];
    const bridge = new OpencodePermissionBridge(fake.session, async (id, reply) => { replies.push([id, reply]); });
    return { fake, replies, bridge };
}

describe('OpencodePermissionBridge', () => {
    it('shows a request in the app joined to its tool call', () => {
        const { fake, bridge } = setup();
        bridge.ask({ id: 'per_1', toolName: 'execute', input: { command: 'ls' }, toolCallId: 'call_1' });
        bridge.ask({ id: 'per_1', toolName: 'execute', input: { command: 'ls' }, toolCallId: 'call_1' });

        expect(fake.state().requests).toEqual({
            per_1: { tool: 'execute', arguments: { command: 'ls' }, createdAt: expect.any(Number), toolUseId: 'call_1' },
        });
        expect(bridge.pendingIds()).toEqual(['per_1']);
    });

    it('forwards app answers to OpenCode', async () => {
        const { fake, replies, bridge } = setup();
        bridge.ask({ id: 'per_1', toolName: 'execute', input: {} });
        bridge.ask({ id: 'per_2', toolName: 'edit', input: {} });
        bridge.ask({ id: 'per_3', toolName: 'edit', input: {} });

        await fake.callRpc('permission', { id: 'per_1', approved: true, decision: 'approved' });
        await fake.callRpc('permission', { id: 'per_2', approved: true, decision: 'approved_for_session' });
        await fake.callRpc('permission', { id: 'per_3', approved: false, decision: 'denied' });

        expect(replies).toEqual([['per_1', 'once'], ['per_2', 'always'], ['per_3', 'reject']]);
        expect(fake.state().requests).toEqual({});
        expect(fake.state().completedRequests?.per_2).toMatchObject({ status: 'approved', decision: 'approved_for_session' });
        expect(fake.state().completedRequests?.per_3).toMatchObject({ status: 'denied' });

        // OpenCode echoes our replies back; nothing changes.
        bridge.resolveExternally('per_1', 'once');
        expect(replies).toHaveLength(3);
    });

    it('clears a request the terminal answered, and ignores a late app answer', async () => {
        const { fake, replies, bridge } = setup();
        bridge.ask({ id: 'per_1', toolName: 'execute', input: {} });
        bridge.resolveExternally('per_1', 'reject');

        expect(fake.state().requests).toEqual({});
        expect(fake.state().completedRequests?.per_1).toMatchObject({ status: 'denied', decision: 'denied' });

        await fake.callRpc('permission', { id: 'per_1', approved: true, decision: 'approved' });
        expect(replies).toEqual([]);
        expect(bridge.pendingIds()).toEqual([]);
    });

    it('rejects pending requests when the turn is aborted', () => {
        const { replies, bridge } = setup();
        bridge.ask({ id: 'per_1', toolName: 'execute', input: {} });
        bridge.abortAll();
        expect(replies).toEqual([['per_1', 'reject']]);
    });

    it('maps app decisions to OpenCode replies', () => {
        expect(opencodeReplyForDecision('approved')).toBe('once');
        expect(opencodeReplyForDecision('approved_for_session')).toBe('always');
        expect(opencodeReplyForDecision('denied')).toBe('reject');
        expect(opencodeReplyForDecision('abort')).toBe('reject');
    });
});
