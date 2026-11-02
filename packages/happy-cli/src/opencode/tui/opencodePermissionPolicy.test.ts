import { describe, expect, it } from 'vitest';
import type { OpencodePermissionReply } from './opencodeEventMapper';
import type { OpencodePermissionRequest } from './opencodePermissionBridge';
import { OpencodePermissionRouter } from './opencodePermissionPolicy';

const request: OpencodePermissionRequest = { id: 'per_1', toolName: 'bash', input: { command: 'ls' } };

function setup(policy: 'auto' | 'ask', replyFails = false) {
    const asked: string[] = [];
    const replies: Array<[string, OpencodePermissionReply]> = [];
    const router = new OpencodePermissionRouter(policy, {
        ask: (r) => { asked.push(r.id); },
        reply: async (id, reply) => {
            replies.push([id, reply]);
            if (replyFails) {
                throw new Error('server gone');
            }
        },
    });
    return { router, asked, replies };
}

describe('OpencodePermissionRouter', () => {
    it('approves once without asking in auto mode, and only once per request', async () => {
        const { router, asked, replies } = setup('auto');
        router.handleAsked(request);
        router.handleAsked(request);
        await Promise.resolve();
        expect(replies).toEqual([['per_1', 'once']]);
        expect(asked).toEqual([]);
    });

    it('hands requests to the bridge in ask mode', () => {
        const { router, asked, replies } = setup('ask');
        router.handleAsked(request);
        expect(asked).toEqual(['per_1']);
        expect(replies).toEqual([]);
    });

    it('asks instead when the automatic reply fails', async () => {
        const { router, asked } = setup('auto', true);
        router.handleAsked(request);
        await new Promise((resolve) => setImmediate(resolve));
        expect(asked).toEqual(['per_1']);
    });

    it('follows policy switches', () => {
        const { router, asked, replies } = setup('auto');
        router.setPolicy('ask');
        router.handleAsked(request);
        expect(router.policy).toBe('ask');
        expect(asked).toEqual(['per_1']);
        expect(replies).toEqual([]);
    });

    it('asks for doom_loop even in auto mode, so the guard stays on', () => {
        const { router, asked, replies } = setup('auto');
        router.handleAsked({ id: 'per_loop', toolName: 'doom_loop', input: {} });
        expect(asked).toEqual(['per_loop']);
        expect(replies).toEqual([]);
    });

    it('asks once for a tool call that needs an outside directory', async () => {
        const { router, asked, replies } = setup('ask');
        router.handleAsked({ id: 'per_dir', toolName: 'external_directory', input: { command: 'ls /etc' }, toolCallId: 'call_1' });
        router.handleReplied('per_dir', 'once');
        router.handleAsked({ id: 'per_bash', toolName: 'bash', input: { command: 'ls /etc' }, toolCallId: 'call_1' });
        await Promise.resolve();
        expect(asked).toEqual(['per_dir']);
        expect(replies).toEqual([['per_bash', 'once']]);
    });

    it('does not carry an allowed directory over to another tool call', () => {
        const { router, asked, replies } = setup('ask');
        router.handleAsked({ id: 'per_dir', toolName: 'external_directory', input: {}, toolCallId: 'call_1' });
        router.handleReplied('per_dir', 'once');
        router.handleAsked({ id: 'per_bash', toolName: 'bash', input: {}, toolCallId: 'call_2' });
        expect(asked).toEqual(['per_dir', 'per_bash']);
        expect(replies).toEqual([]);
    });

    it('keeps asking when the directory was refused', () => {
        const { router, asked, replies } = setup('ask');
        router.handleAsked({ id: 'per_dir', toolName: 'external_directory', input: {}, toolCallId: 'call_1' });
        router.handleReplied('per_dir', 'reject');
        router.handleAsked({ id: 'per_bash', toolName: 'bash', input: {}, toolCallId: 'call_1' });
        expect(asked).toEqual(['per_dir', 'per_bash']);
        expect(replies).toEqual([]);
    });

    it('asks for every request of a call when none of them was about a directory', () => {
        const { router, asked } = setup('ask');
        router.handleAsked({ id: 'per_1', toolName: 'bash', input: {}, toolCallId: 'call_1' });
        router.handleReplied('per_1', 'once');
        router.handleAsked({ id: 'per_2', toolName: 'bash', input: {}, toolCallId: 'call_1' });
        expect(asked).toEqual(['per_1', 'per_2']);
    });

    it('does not bring back a request that was already answered', () => {
        const { router, asked, replies } = setup('ask');
        router.handleReplied('per_1', 'once');
        router.handleAsked(request);
        expect(asked).toEqual([]);
        expect(replies).toEqual([]);
    });
});
