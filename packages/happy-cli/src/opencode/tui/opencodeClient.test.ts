import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import { createOpencodeMessageId, OpencodeClient, OpencodeHttpError } from './opencodeClient';
import type { OpencodeEvent } from './opencodeEventMapper';

type Recorded = { method: string; path: string; query: URLSearchParams; auth?: string; body: string };

/** A real local HTTP server standing in for `opencode serve`. */
async function startStub(handler: (req: IncomingMessage, res: ServerResponse, body: string) => void): Promise<{ url: string; requests: Recorded[]; server: Server }> {
    const requests: Recorded[] = [];
    const server = createServer((req, res) => {
        let body = '';
        req.on('data', (chunk) => { body += chunk; });
        req.on('end', () => {
            const url = new URL(req.url ?? '/', 'http://127.0.0.1');
            requests.push({ method: req.method ?? '', path: url.pathname, query: url.searchParams, auth: req.headers.authorization, body });
            handler(req, res, body);
        });
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address() as AddressInfo;
    return { url: `http://127.0.0.1:${port}`, requests, server };
}

const servers: Server[] = [];
afterEach(async () => {
    await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    })));
});

describe('createOpencodeMessageId', () => {
    it('produces ids in OpenCode format that sort by creation order', () => {
        const ids = [createOpencodeMessageId(1_792_999_365_465), createOpencodeMessageId(1_792_999_365_465), createOpencodeMessageId(1_792_999_365_466)];
        for (const id of ids) {
            expect(id).toMatch(/^msg_[0-9a-f]{12}[0-9A-Za-z]{14}$/);
        }
        expect([...ids].sort()).toEqual(ids);
        // Same prefix scheme as ids OpenCode generated at that time.
        expect(ids[0].slice(0, 10)).toBe('msg_177171');
    });
});

describe('OpencodeClient', () => {
    it('authenticates, scopes requests to the directory and posts prompts with our id', async () => {
        const stub = await startStub((req, res) => {
            if (req.url?.startsWith('/session?')) {
                res.setHeader('content-type', 'application/json');
                res.end(JSON.stringify({ id: 'ses_1', title: 'New session - x' }));
                return;
            }
            res.statusCode = 204;
            res.end();
        });
        servers.push(stub.server);
        const client = new OpencodeClient({ url: stub.url, password: 'pw', directory: '/tmp/project dir' });

        expect(await client.createSession()).toEqual({ id: 'ses_1', title: 'New session - x' });
        await client.promptAsync('ses_1', { text: 'hi', messageId: 'msg_x', model: { providerID: 'p', modelID: 'm' }, agent: 'plan' });
        await client.replyPermission('per_1', 'always');

        expect(stub.requests.map((r) => `${r.method} ${r.path}`)).toEqual([
            'POST /session',
            'POST /session/ses_1/prompt_async',
            'POST /permission/per_1/reply',
        ]);
        for (const request of stub.requests) {
            expect(request.auth).toBe(`Basic ${Buffer.from('opencode:pw').toString('base64')}`);
            expect(request.query.get('directory')).toBe('/tmp/project dir');
        }
        expect(JSON.parse(stub.requests[1].body)).toEqual({
            messageID: 'msg_x',
            model: { providerID: 'p', modelID: 'm' },
            agent: 'plan',
            parts: [{ type: 'text', text: 'hi' }],
        });
        expect(JSON.parse(stub.requests[2].body)).toEqual({ reply: 'always' });
    });

    it('lists, answers and dismisses questions', async () => {
        const stub = await startStub((req, res) => {
            res.setHeader('content-type', 'application/json');
            res.end(req.method === 'GET' ? JSON.stringify([{ id: 'que_1', sessionID: 'ses_1', questions: [] }]) : 'true');
        });
        servers.push(stub.server);
        const client = new OpencodeClient({ url: stub.url, password: 'pw', directory: '/tmp' });

        expect(await client.listQuestions()).toEqual([{ id: 'que_1', sessionID: 'ses_1', questions: [] }]);
        await client.replyQuestion('que_1', [['Red'], ['a', 'b']]);
        await client.rejectQuestion('que_2');

        expect(stub.requests.map((r) => `${r.method} ${r.path}`)).toEqual([
            'GET /question',
            'POST /question/que_1/reply',
            'POST /question/que_2/reject',
        ]);
        expect(JSON.parse(stub.requests[1].body)).toEqual({ answers: [['Red'], ['a', 'b']] });
    });

    it('raises OpencodeHttpError with the status on failures and reports health', async () => {
        const stub = await startStub((_req, res) => {
            res.statusCode = 401;
            res.end('Unauthorized');
        });
        servers.push(stub.server);
        const client = new OpencodeClient({ url: stub.url, password: 'wrong', directory: '/tmp' });
        await expect(client.getSession('ses_1')).rejects.toMatchObject({ status: 401 });
        await expect(client.getSession('ses_1')).rejects.toBeInstanceOf(OpencodeHttpError);
        expect(await client.healthy()).toBe(false);
    });

    it('streams events, splitting chunks at event boundaries, and reconnects after a drop', async () => {
        let connections = 0;
        const stub = await startStub((_req, res) => {
            connections++;
            res.writeHead(200, { 'content-type': 'text/event-stream' });
            if (connections === 1) {
                // One event split across writes, then the stream drops.
                res.write('data: {"type":"server.connected","properties":{}}\n\ndata: {"type":"session.idle",');
                setTimeout(() => res.end('"properties":{"sessionID":"ses_1"}}\n\n'), 20);
                return;
            }
            res.write('data: {"type":"session.status","properties":{"sessionID":"ses_1","status":{"type":"busy"}}}\n\n');
        });
        servers.push(stub.server);
        const client = new OpencodeClient({ url: stub.url, password: 'pw', directory: '/tmp' });

        const controller = new AbortController();
        const events: OpencodeEvent[] = [];
        let connects = 0;
        const done = client.streamEvents({
            signal: controller.signal,
            onConnected: () => { connects++; },
            onEvent: (event) => {
                events.push(event);
                if (events.length === 3) {
                    controller.abort();
                }
            },
        });
        await done;

        expect(events.map((event) => event.type)).toEqual(['server.connected', 'session.idle', 'session.status']);
        expect(events[1].properties).toEqual({ sessionID: 'ses_1' });
        expect(connects).toBe(2);
    });
});
