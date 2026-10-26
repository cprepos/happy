# Voice Architecture

How the voice assistant works in the self-hosted build: the app talks to a
voice agent through a LiveKit room, the agent runs speech-to-text, an LLM and
text-to-speech on our own machines, and it reaches back into the app to send
messages to coding sessions and answer permission requests.

There is no ElevenLabs, RevenueCat gate or usage quota. The services are
described in `selfhost/VOICE_SERVICES.md`.

## Services

| Service | Local address | Notes |
|---------|---------------|-------|
| LiveKit | `ws://127.0.0.1:7880` | public at `wss://livekit.girthbass.duckdns.org` |
| STT | `ws://127.0.0.1:8090/v1/stream` | Nemotron streaming |
| TTS | `http://127.0.0.1:8880/v1/audio/speech` | Kokoro |
| LLM | `http://127.0.0.1:8000/v1` | vLLM, model `voice-llm` |

Keys live in `selfhost/.env.voice` (template: `selfhost/.env.voice.example`).

```text
 Happy app                 Happy server                 LiveKit            Voice agent worker
 ─────────                 ────────────                 ───────            ──────────────────
 tap mic ──POST /v1/voice/conversations──>
           <── { conversationId, roomName, token, url }
 join room (token) ───────────────────────────────────────> room <── dispatch "happy-voice"
 <──────────── RPC happy.getConfig ───────────────────────────────────────── worker
 mic audio ───────────────────────────────────────────────────────────────> STT → LLM → TTS
 <──────────── agent audio, lk.agent.state ──────────────────────────────── worker
 <──────────── RPC sendMessageToSession / processPermissionRequest ──────── worker
 data happy.context / happy.text ─────────────────────────────────────────> worker
```

## Server: `POST /v1/voice/conversations`

- Uses the normal Happy auth. Body: `{ sessionId?, language? }`; unknown fields
  are ignored so older clients keep working.
- Returns `{ allowed: true, conversationId, roomName, token, url }`:
  - `roomName` is `happy-voice-<conversationId>`.
  - `token` is a LiveKit JWT for identity `user-<accountId>` with roomJoin,
    canPublish, canSubscribe and canPublishData, valid for 15 minutes, whose
    room config dispatches the agent named `happy-voice`.
  - `url` is `LIVEKIT_PUBLIC_URL`.
- Each conversation is stored as a `VoiceConversation` row.
- Env: `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_PUBLIC_URL`.
- `GET /v1/voice/usage` keeps its response shape but always reports unlimited.
- Zod schemas for both live in `packages/happy-wire/src/voice.ts`. The
  `allowed: false` variant stays in the type for compatibility.

## Room protocol

**Participants.** The app joins as the user participant. The worker joins as
an agent participant (`kind = agent`) through explicit dispatch `happy-voice`.

**Config handshake.** When the worker joins it waits for the first non-agent
participant and calls RPC `happy.getConfig` on it (empty payload, 10 s
timeout). The app answers with the JSON string
`{ systemPrompt, firstMessage, initialContext, language, sessionId }`, the
fields of `VoiceSessionConfig` in `sources/realtime/types.ts`. The worker
combines `systemPrompt` with its own base prompt, adds `initialContext` as a
context message, speaks `firstMessage` if present, and uses `language` (an ISO
code such as `en`, from `getVoiceLanguageCode` in
`sources/constants/Languages.ts`) to pick STT and TTS voices where supported.

**App to agent** (reliable data messages, UTF-8 plain text):

| Topic | Meaning | App call |
|-------|---------|----------|
| `happy.context` | Silent context; appended, no reply | `sendContextualUpdate` |
| `happy.text` | Injected user turn; the agent replies | `sendTextMessage` |

The app queues these until an agent participant is in the room.

**Agent to app tool calls.** RPCs to the user participant, JSON string payload,
string response, errors raised as RPC errors, 30 s timeout. Names and
parameters must match `sources/realtime/realtimeClientTools.ts`, which wins if
anything disagrees:

- `sendMessageToSession` `{ sessionId: string, message: string }` sends text to
  a coding session via `sync.sendMessage`.
- `processPermissionRequest` `{ requestId: string, decision: "allow" | "deny" }`
  finds the session holding that request and allows or denies it.

**Agent state.** The worker publishes the standard LiveKit Agents attribute
`lk.agent.state` (`initializing`, `listening`, `thinking`, `speaking`). The
app maps it to `realtimeMode`; only `speaking` counts as the agent talking.

**Ending.** The app disconnects; the worker closes its session and the room
empties.

## App components

```text
SessionView.tsx               UI: mic button, starts and stops voice
RealtimeSession.ts            Lifecycle: start/stop, token fetch, session routing state
RealtimeVoiceSession.tsx      Native LiveKit client (@livekit/react-native + livekit-client)
RealtimeVoiceSession.web.tsx  Web LiveKit client (livekit-client), same interface
RealtimeProvider(.web).tsx    Wraps the app; a new room per voice session
hooks/voiceHooks.ts           Formats app events and routes them to the agent
hooks/contextFormatters.ts    Text for session context, messages, permissions
realtimeClientTools.ts        Tools the agent calls over RPC
voiceSystemPrompt.ts          App-side system prompt sent in happy.getConfig
voiceConfig.ts                Flags and constants
types.ts                      VoiceSession interface and VoiceSessionConfig
sync/apiVoice.ts              POST /v1/voice/conversations client
```

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
LiveKit room connection state.

## Lifecycle

```text
User taps mic
  └─> voiceHooks.onVoiceStarted(sessionId)      builds initialContext
  └─> startRealtimeSession(sessionId, context)
        ├─> POST /v1/voice/conversations       token, url, roomName
        ├─> currentSessionId = sessionId
        └─> voiceSession.startSession(...)     joins the room, registers RPC
                                               handlers, returns conversationId

User taps mic again (or leaves)
  └─> stopRealtimeSession()
        ├─> voiceSession.endSession()          disconnects from the room
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

## History

`docs/paid-voice.md` and `docs/plans/elevenlabs-voice-usage-gating.md` describe
the earlier ElevenLabs design with paid gating. They are kept for reference
only.
