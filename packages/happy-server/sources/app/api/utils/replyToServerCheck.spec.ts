import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import cors from '@fastify/cors';
import fastifyStatic from '@fastify/static';
import fastify, { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { replyToServerCheck, serverBanner } from '@/app/api/utils/replyToServerCheck';

const browserAccept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
const indexHtml = '<!doctype html><html><head></head><body>webapp</body></html>';

describe('replyToServerCheck', () => {
    let staticDir: string;
    let app: FastifyInstance;
    let contentTypesSeenByOnSend: unknown[];

    beforeEach(async () => {
        staticDir = fs.mkdtempSync(path.join(os.tmpdir(), 'happy-server-check-'));
        fs.writeFileSync(path.join(staticDir, 'index.html'), indexHtml);
        contentTypesSeenByOnSend = [];

        // Registered in the same order as startApi.
        app = fastify();
        app.register(cors, { origin: '*' });
        app.register(fastifyStatic, { root: staticDir, prefix: '/', decorateReply: false, wildcard: false });
        app.addHook('onRequest', replyToServerCheck);
        app.addHook('onSend', async (_request, reply, payload) => {
            contentTypesSeenByOnSend.push(reply.getHeader('content-type'));
            return payload;
        });
        await app.ready();
    });

    afterEach(async () => {
        await app.close();
        fs.rmSync(staticDir, { recursive: true, force: true });
    });

    it('answers a plain-text check with the banner', async () => {
        const response = await app.inject({ method: 'GET', url: '/', headers: { accept: 'text/plain' } });

        expect(response.statusCode).toBe(200);
        expect(response.body).toBe(serverBanner);
        expect(response.headers['content-type']).toContain('text/plain');
    });

    it('answers a check without an Accept header with the banner', async () => {
        const response = await app.inject({ method: 'GET', url: '/' });

        expect(response.body).toBe(serverBanner);
    });

    it('sends the CORS headers, as a web client validating a server needs them', async () => {
        const response = await app.inject({
            method: 'GET',
            url: '/',
            headers: { accept: '*/*', origin: 'https://app.example.com' },
        });

        expect(response.body).toBe(serverBanner);
        expect(response.headers['access-control-allow-origin']).toBe('*');
    });

    it('gives a browser the webapp', async () => {
        const response = await app.inject({ method: 'GET', url: '/', headers: { accept: browserAccept } });

        expect(response.statusCode).toBe(200);
        expect(response.body).toBe(indexHtml);
        expect(response.headers['content-type']).toContain('text/html');
    });

    it('leaves other webapp files to the static server', async () => {
        const response = await app.inject({ method: 'GET', url: '/index.html', headers: { accept: '*/*' } });

        expect(response.body).toBe(indexHtml);
    });

    it('shows onSend hooks a content type that the HTML injection skips', async () => {
        await app.inject({ method: 'GET', url: '/', headers: { accept: 'text/plain' } });

        expect(contentTypesSeenByOnSend).toHaveLength(1);
        expect(contentTypesSeenByOnSend[0]).not.toContain('text/html');
    });
});
