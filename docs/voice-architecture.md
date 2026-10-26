# Voice Architecture

How the voice assistant works in the self-hosted build: the app streams audio
to happy-server over one WebSocket, happy-server sits in a LiveKit room on the
app's behalf, and a voice agent in the same room runs speech-to-text, an LLM
and text-to-speech on our own machines. The agent reaches back into the app
(through the server) to send messages to coding sessions and answer
permission requests.

The app never talks to LiveKit. LiveKit lives only on the docker network: it
has no public URL, no Caddy site, no router forwards and no ufw rules.

There is no ElevenLabs, RevenueCat gate or usage quota. The services are
described in `selfhost/VOICE_SERVICES.md`.

## Services

| Service | Local address | Notes |
|---------|---------------|-------|
| Voice stream | `wss://<happy-server>/v1/voice/stream` | the app's only voice connection |
| LiveKit | `ws://livekit:7880` (docker network), `ws://127.0.0.1:7880` (host) | internal only; RTC ports 7881/tcp and 7882/udp stay on the container IP |
| STT | `ws://127.0.0.1:8090/v1/stream` | Nemotron streaming |
| TTS | `http://127.0.0.1:8880/v1/audio/speech` | Kokoro |
| LLM | `http://127.0.0.1:9080/v1` | the host's vLLM (`VOICE_LLM_BASE_URL`); optional local `voice-llm` on 8000 |

Keys live in `selfhost/.env.voice` (template: `selfhost/.env.voice.example`).
LiveKit runs from `selfhost/compose.voice.yml` with `selfhost/livekit.yaml`,
attached to happy-server's compose network (`happy-selfhost_default`, alias
`livekit`). happy-server reaches it at `LIVEKIT_URL` (default
`ws://livekit:7880`); the agent worker, on the host network, uses the
loopback-only publish of port 7880. Media goes to the container IP in both
cases.

```text
 ┌─ App (web; native soon) ─┐        ┌─ happy-server ──┐      ┌─ LiveKit ────────┐      ┌─ voice agent ────┐
 │ mic → 16 kHz PCM16       │  wss   │ voice bridge    │      │ room             │      │ STT (Nemotron)   │
 │                          │ ─────> │ (rtc-node),     │ ───> │ happy-voice-<id> │ ───> │ LLM (vLLM)       │
 │ speaker ← jitter buffer  │ <───── │ joins as        │ <─── │                  │ <─── │ TTS (Kokoro)     │
 │   40-120 ms, 24 kHz      │        │ user-<account>  │      │ docker net only  │      │ dispatch         │
 └──────────────────────────┘        └─────────────────┘      └──────────────────┘      │ "happy-voice"    │
       /v1/voice/stream: binary 20 ms audio frames + JSON control                       └──────────────────┘
       (hello, text, rpcResult, end  /  ready, agent, rpc, flush, error)
```

## Wire protocol: `/v1/voice/stream`

Defined in `packages/happy-wire/src/voiceStream.ts` (constants and Zod
schemas, shared by app and server). One WebSocket per conversation:

- **Binary frames** carry audio: PCM 16-bit signed little-endian, mono, one
  20 ms frame per message.
  - App to server: microphone at 16 kHz, exactly 320 samples (640 bytes). The
    server closes the stream with `bad_request` on any other size.
  - Server to app: agent speech at 24 kHz, 480 samples per frame.
- **Text frames** carry one JSON control message each.

App to server:

| Message | Fields | Meaning |
|---------|--------|---------|
| `hello` | `token`, `sessionId?`, `language?` | Must be first, within 5 s. `token` is the account's Happy token (the REST Bearer token). |
| `text` | `topic` (`happy.text` or `happy.context`), `text` | Relayed to the agent as room data |
| `rpcResult` | `id`, `result?` or `error?` | Answer to an `rpc` |
| `end` | | Leave the room and close |

Server to app:

| Message | Fields | Meaning |
|---------|--------|---------|
| `ready` | `conversationId` | The server is in the room; audio may flow. Audio sent before this is dropped. |
| `agent` | `present`, `state?` | The agent joined or left, or its `lk.agent.state` changed (`initializing`, `idle`, `listening`, `thinking`, `speaking`) |
| `rpc` | `id`, `method`, `payload` | The agent calls the app: `happy.getConfig`, `sendMessageToSession` or `processPermissionRequest`; `payload` is the agent's JSON string |
| `flush` | | The agent was interrupted: drop agent audio not yet played |
| `error` | `code` (`unauthorized`, `bad_request`, `unavailable`, `internal`), `message` | Followed by close (1008 for `unauthorized`/`bad_request`, else 1011) |

Unknown client messages after `hello` are ignored, so newer apps can talk to
older servers.

## Server: voice bridge

`packages/happy-server/sources/app/api/voiceStream.ts` serves the WebSocket on
the API server's `upgrade` event, next to socket.io (which keeps
`/v1/updates`). Per connection it:

1. verifies the `hello` token like a REST Bearer token, and checks that
   `sessionId`, if given, is one of the account's own sessions;
2. records a `VoiceConversation` row (room `happy-voice-<conversationId>`);
3. mints a LiveKit token for identity `user-<accountId>` whose room config
   dispatches the agent named `happy-voice`;
4. joins the room through `VoiceBridge`
   (`packages/happy-server/sources/app/voice/voiceBridge.ts`, using
   `@livekit/rtc-node`, loaded only when the first voice stream starts) and
   answers `ready`;
5. on `end`, socket close or the room closing, leaves the room and stores the
   conversation's duration.

`VoiceBridge` publishes the app's frames as the user's microphone track, reads
the agent's track as 24 kHz 20 ms frames and sends them down, relays the
`happy.text` / `happy.context` topics (queued, up to 100, until the agent
joins), forwards the agent's RPCs to the app as `rpc` messages, reports the
agent's presence and `lk.agent.state` as `agent` messages, and turns the
agent's `happy.interrupted` announcement into `flush`. Only the dispatched
agent participant may call RPCs; anyone else gets an error.

Env: `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` (same pair as
`selfhost/.env.voice`), `LIVEKIT_URL`. Without the key pair the stream answers
`unavailable`.

**Legacy REST route.** `POST /v1/voice/conversations` still returns
`{ allowed: true, conversationId, roomName, token, url }`, a LiveKit token for
the app to join the room itself. Only the native app uses it until it moves to
the voice stream, and `url` (`LIVEKIT_PUBLIC_URL`) no longer reaches LiveKit
from outside. `GET /v1/voice/usage` keeps its response shape but always
reports unlimited. Zod schemas for both live in
`packages/happy-wire/src/voice.ts`.

## Latency design

The goal is that the user never hears the agent late, and the agent never
hears the user late, even after a network stall. Every buffer is small and
drops old audio instead of growing:

- **Uplink, app.** Microphone frames are sent as soon as they are encoded;
  frames are dropped while more than about 1 s is unsent on the socket.
- **Uplink, server.** The LiveKit audio source buffers 100 ms; frames are
  dropped while more than 60 ms is queued.
- **Downlink, server.** Agent audio is dropped while more than 64 KB (about
  1.3 s) is unsent to the app. The socket has Nagle off and no compression.
- **Downlink, app.** A jitter buffer in an AudioWorklet starts playing at
  40 ms of buffered audio. Each underrun that looks like network jitter
  (data back within 250 ms) raises the start level by 20 ms, up to 120 ms;
  10 s without one lowers it by 10 ms, back to 40 ms. Excess latency drains
  by playing 1% fast. Underruns and flushes fade over 4 ms instead of
  clicking.
- **Barge-in.** When the user talks over the agent, the agent publishes an
  empty message on topic `happy.interrupted`; the server sends `flush` and the
  jitter buffer drops everything queued, so the agent stops at once instead of
  finishing what was already buffered.

`make voice-stream-e2e` (`selfhost/scripts/voice-stream-e2e.mjs`) measures end
of speech to first agent audio and downlink jitter through the real
`/v1/voice/stream`.

## Room protocol

The server speaks this on the app's behalf; the app sees the same thing as
voice stream messages.

**Participants.** The server joins as the user participant `user-<accountId>`.
The worker joins as an agent participant (`kind = agent`) through explicit
dispatch `happy-voice`.

**Config handshake.** When the worker joins it waits for the first non-agent
participant and calls RPC `happy.getConfig` on it (empty payload, 10 s
timeout); the server forwards it to the app as an `rpc` message. The app
answers with the JSON string
`{ systemPrompt, firstMessage, initialContext, language, sessionId }`, the
fields of `VoiceSessionConfig` in `sources/realtime/types.ts`. The worker
combines `systemPrompt` with its own base prompt, adds `initialContext` as a
context message, speaks `firstMessage` if present, and uses `language` (an ISO
code such as `en`, from `getVoiceLanguageCode` in
`sources/constants/Languages.ts`) to pick STT and TTS voices where supported.
Per-chat voice and speed choices in this answer are upcoming.

**App to agent** (reliable data messages, UTF-8 plain text):

| Topic | Meaning | App call |
|-------|---------|----------|
| `happy.context` | Silent context; appended, no reply | `sendContextualUpdate` |
| `happy.text` | Injected user turn; the agent replies | `sendTextMessage` |

The app queues these until the stream is `ready` and the agent is present.

**Agent to app tool calls.** RPCs to the user participant, JSON string payload,
string response, errors raised as RPC errors, 30 s timeout (the server honors
the agent's own deadline up to 60 s). Names and parameters must match
`sources/realtime/realtimeClientTools.ts`, which wins if anything disagrees:

- `sendMessageToSession` `{ sessionId: string, message: string }` sends text to
  a coding session via `sync.sendMessage`.
- `processPermissionRequest` `{ requestId: string, decision: "allow" | "deny" }`
  finds the session holding that request and allows or denies it.

**Agent state.** The worker publishes the standard LiveKit Agents attribute
`lk.agent.state`. The app maps it to `realtimeMode`; only `speaking` counts as
the agent talking.

**Interruptions.** The worker publishes an empty reliable message on
`happy.interrupted` whenever its speech is interrupted.

**Ending.** The app sends `end` (or closes the socket); the server leaves the
room, the worker closes its session and the room empties.

## App components

```text
SessionView.tsx               UI: mic button, starts and stops voice
RealtimeSession.ts            Lifecycle: start/stop, session routing state
happyVoiceSession.ts          Voice stream client (WebSocket, protocol, tools); platform audio injected
webVoiceAudio.ts              Web audio: one AudioContext, mic capture and playback worklets
voiceAudioWorklets.ts         Worklet source: 16 kHz downsampler, PCM16 encoder, VAD, jitter buffer
RealtimeVoiceSession.web.tsx  Web: HappyVoiceSession + web audio
RealtimeVoiceSession.tsx      Native: still LiveKit direct (livekitVoiceSession.ts) until it moves to the stream
RealtimeProvider(.web).tsx    Wraps the app; a fresh voice component per conversation
hooks/voiceHooks.ts           Formats app events and routes them to the agent
hooks/contextFormatters.ts    Text for session context, messages, permissions
realtimeClientTools.ts        Tools the agent calls over RPC
voiceSystemPrompt.ts          App-side system prompt sent in happy.getConfig
voiceConfig.ts                Flags and constants
types.ts                      VoiceSession interface and VoiceSessionConfig
sync/apiVoice.ts              POST /v1/voice/conversations client (native only)
```

`HappyVoiceSession` takes a `HappyVoiceAudio` (`prime`, `start`, `play`,
`flush`, `stop`), so native only needs its own audio to use the same stream.
On web, `prime` runs inside the tap that starts voice (Safari only allows
audio to start there), the microphone uses echo cancellation and noise
suppression, and the socket and microphone come up in parallel.

## Session routing

A module-level `currentSessionId` in `RealtimeSession.ts` records the session
the user is looking at. `voiceHooks.onSessionFocus()` updates it when the user
navigates while voice is active, and compares against it to avoid re-sending
context for the session that already has focus. The agent's tools carry an
explicit `sessionId` or `requestId`, so the focused session is context for the
agent, not a hidden routing target.

## Voice start

`onVoiceStarted(sessionId)` builds the initial context:

1. a session directory, one line per active session (id and summary), so the
   agent knows every target;
2. the focused session in full via `injectSessionContext(sessionId)`:
   metadata, path, summary and message history.

This becomes `initialContext` in the `happy.getConfig` answer.

## Context delivery

- **`sendContext()`** calls `sendContextualUpdate` (topic `happy.context`).
  The agent takes it in silently. Sent immediately, never queued. Used for new
  messages, focus changes, sessions going online or offline, and full session
  dumps.
- **`sendPrompt()`** calls `sendTextMessage` (topic `happy.text`) and makes the
  agent respond. Prompts are queued in `pendingPrompts[]` while someone is
  speaking and flushed as one joined message when `realtimeMode` returns to
  `idle`. Used for permission requests and "agent finished" events.

`injectSessionContext(sessionId)` is shared by voice start and focus changes and
tracks already-shown sessions in `shownSessions`.

## Realtime mode

| Mode | Meaning | Source |
|------|---------|--------|
| `idle` | Nobody is talking | default, or agent state not `speaking` |
| `agent-speaking` | The agent is producing audio | `lk.agent.state = speaking` |
| `user-speaking` | The user is talking | local microphone activity |

`agent-speaking` wins over `user-speaking`. `realtimeStatus` follows the
voice stream: `connecting` until `ready`, then `connected`, and `error` or
`disconnected` when it ends.

## Lifecycle

```text
User taps mic
  └─> voiceHooks.onVoiceStarted(sessionId)      builds initialContext
  └─> startRealtimeSession(sessionId, context)
        ├─> voiceSession.prepare()             primes audio inside the tap
        ├─> currentSessionId = sessionId
        └─> voiceSession.startSession(...)     opens /v1/voice/stream, sends hello,
                                               starts the mic; resolves on ready
                                               with the conversationId

User taps mic again (or leaves)
  └─> stopRealtimeSession()
        ├─> voiceSession.endSession()          sends end, closes the socket,
                                               releases the mic
        ├─> currentSessionId = null
        └─> voiceHooks.onVoiceStopped()
```

## Settings

The voice settings screen has one setting, the assistant language
(`voiceAssistantLanguage`). The former custom-agent, direct-connection and
usage/paywall settings were removed; old stored values are ignored.

## Testing

- `selfhost/scripts/voice-smoke.sh` checks the services.
- `make voice-try` serves `selfhost/voice-test/`, a loopback-only page that
  tries TTS, STT and a full turn against the services.
- `make voice-agent-e2e` runs a headless fake app in the LiveKit room against
  the worker.
- `make voice-stream-e2e` runs a full conversation through happy-server's
  `/v1/voice/stream` and reports latency and jitter.
- `selfhost/cutover/check-no-public-livekit.sh` checks that no public path
  reaches LiveKit and the internal paths still do.

## History

`docs/paid-voice.md` and `docs/plans/elevenlabs-voice-usage-gating.md` describe
the earlier ElevenLabs design with paid gating. They are kept for reference
only.
