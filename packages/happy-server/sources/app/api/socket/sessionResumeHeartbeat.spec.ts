import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import type { Fastify } from '@/app/api/types';
import { startSocket } from '@/app/api/socket';
import { eventRouter } from '@/app/events/eventRouter';

const { rows, update } = vi.hoisted(() => {
    const rows: Record<string, { id: string; accountId: string; active: boolean; lastActiveAt: Date }> = {};
    const update = vi.fn(async ({ where, data }: any) => Object.assign(rows[where.id], data));
    return { rows, update };
});

vi.mock('@/app/auth/auth', () => ({
    // The token is the user id.
    auth: { verifyToken: async (token: string) => ({ userId: token }) }
}));

vi.mock('@/storage/db', () => ({
    db: {
        session: {
            update,
            findUnique: async ({ where }: any) => rows[where.id]?.accountId === where.accountId ? { ...rows[where.id] } : null
        }
    }
}));

/** Minimal Socket.IO client over the Engine.IO polling transport. */
class PollingClient {
    private buffer: string[] = [];

    private constructor(private url: string) { }

    static async connect(base: string, auth: Record<string, string>): Promise<PollingClient> {
        const open = await fetch(base);
        const sid = (JSON.parse((await open.text()).slice(1)) as { sid: string }).sid;
        const client = new PollingClient(`${base}&sid=${sid}`);
        await client.post(`40${JSON.stringify(auth)}`);
        const reply = await client.take((p) => p.startsWith('40') || p.startsWith('44'));
        if (!reply.startsWith('40')) throw new Error(`connect refused: ${reply}`);
        return client;
    }

    private async post(body: string) {
        await (await fetch(this.url, { method: 'POST', body })).text();
    }

    private async take(match: (packet: string) => boolean): Promise<string> {
        while (true) {
            const index = this.buffer.findIndex(match);
            if (index >= 0) return this.buffer.splice(index, 1)[0];
            const packets = (await (await fetch(this.url)).text()).split('\x1e');
            for (const packet of packets) {
                if (packet === '2') await this.post('3'); // Engine.IO heartbeat
                else this.buffer.push(packet);
            }
        }
    }

    emit(event: string, ...args: unknown[]) {
        return this.post(`42${JSON.stringify([event, ...args])}`);
    }

    /** The next `ephemeral` the server sent this client. */
    async nextEphemeral(): Promise<any> {
        const packet = await this.take((p) => p.startsWith('42["ephemeral",'));
        return JSON.parse(packet.slice(2))[1];
    }
}

describe('a session resumed right after it stopped', () => {
    const httpServer = createServer();
    let base = '';

    const owner = (sessionId: string) => PollingClient.connect(base, { token: 'u1', clientType: 'session-scoped', sessionId });

    beforeAll(async () => {
        startSocket({ server: httpServer } as unknown as Fastify);
        await new Promise<void>((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
        base = `http://127.0.0.1:${(httpServer.address() as AddressInfo).port}/v1/updates/?EIO=4&transport=polling`;
    });

    afterAll(async () => {
        await eventRouter['io'].close();
    });

    it('reads as alive on the phone from its new owner\'s first beat, and on the server soon after', async () => {
        const started = Date.now() - 1000;
        rows.s1 = { id: 's1', accountId: 'u1', active: true, lastActiveAt: new Date(started) };
        const phone = await PollingClient.connect(base, { token: 'u1', clientType: 'user-scoped' });

        const stopped = await owner('s1');
        await stopped.emit('session-alive', { sid: 's1', time: started + 1, thinking: false });
        expect(await phone.nextEphemeral()).toMatchObject({ type: 'activity', id: 's1', active: true });

        // Stopped with killSession: the owner says so as it exits.
        await stopped.emit('session-end', { sid: 's1', time: Date.now() });
        expect(await phone.nextEphemeral()).toMatchObject({ type: 'activity', id: 's1', active: false });
        expect(rows.s1.active).toBe(false);

        // A beat still on its way from the stopped owner stays ignored...
        const late = Date.now();
        await stopped.emit('session-alive', { sid: 's1', time: late, thinking: false });

        // ...and the owner a Resume started connects seconds later and beats.
        await new Promise((resolve) => setTimeout(resolve, 5));
        const resumed = await owner('s1');
        const beat = Date.now();
        await resumed.emit('session-alive', { sid: 's1', time: beat, thinking: false });

        const next = await phone.nextEphemeral();
        expect(next).toMatchObject({ type: 'activity', id: 's1', active: true });
        expect(next.activeAt).toBeGreaterThan(late);

        // A list read from here on says so too, within the 5s batch.
        await vi.waitFor(() => expect(rows.s1.active).toBe(true), { timeout: 7000, interval: 100 });
    }, 15000);
});
