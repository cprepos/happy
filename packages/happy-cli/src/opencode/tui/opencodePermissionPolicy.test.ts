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
});
