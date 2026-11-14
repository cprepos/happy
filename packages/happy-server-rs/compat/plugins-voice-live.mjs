// Plugins: the voice stream into a real LiveKit room (plugins-voice-live.env).
// What the agent says is not deterministic, so each run is reduced to what
// must hold on both servers: `ready` with the conversation id, the agent
// joining, audio and agent messages arriving, RPCs answered, `end` closing
// with 1000 and the duration being recorded.
import { login } from './phase2.mjs';
import { stream } from './plugins-voice.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function scenario(t, { sql }) {
    const token = await login(t, 1);
    const H = { authorization: 'Bearer ' + token };
    const s = await t.req('create session', 'POST', '/v1/sessions', { headers: H, body: { tag: 'live', metadata: 'm' } });
    const summary = {};
    const quiet = { note: () => {} };
    quiet.base = t.base;
    const { got, closed } = await stream(quiet, 'live', async (ws) => {
        ws.on('message', (data, isBinary) => {
            if (isBinary) return;
            const m = JSON.parse(data.toString());
            // Answer the agent's RPCs the way an app without that method does.
            if (m.type === 'rpc') ws.send(JSON.stringify({ type: 'rpcResult', id: m.id, error: 'not supported in compat' }));
        });
        ws.send(JSON.stringify({ type: 'hello', token, sessionId: s.session.id, language: 'en' }));
        const start = Date.now();
        while (Date.now() - start < 25_000) {
            await sleep(250);
            if (ws.readyState !== 1) return;
        }
        // Speak: 2 s of 20 ms silence frames, then a typed message.
        for (let i = 0; i < 100; i++) {
            ws.send(Buffer.alloc(640));
            await sleep(20);
        }
        ws.send(JSON.stringify({ type: 'text', topic: 'happy.text', text: 'hello' }));
        await sleep(5000);
        ws.send(JSON.stringify({ type: 'end' }));
    }, { wait: 5000 });
    const types = got.map((m) => (m.binary !== undefined ? 'audio' : m.type));
    summary.firstMessage = types[0];
    summary.ready = got.find((m) => m.type === 'ready') ? 'ready' : null;
    summary.readyIdIsUuid = /^[0-9a-f-]{36}$/.test(got.find((m) => m.type === 'ready')?.conversationId ?? '');
    summary.agentPresent = got.some((m) => m.type === 'agent' && m.present === true);
    summary.audio = types.includes('audio');
    summary.kinds = [...new Set(types)].sort();
    summary.errors = got.filter((m) => m.type === 'error');
    summary.closed = closed;
    t.note('live stream', summary);
    await sleep(1000);
    t.note('live conversation', (await sql(`SELECT "sessionId" IS NOT NULL, "language", "durationSecs" BETWEEN 20 AND 60 FROM "VoiceConversation"`)).trim());
}

export function normalize(s) {
    return s;
}
