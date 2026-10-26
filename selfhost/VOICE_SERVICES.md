# Voice services contract

This document is for whoever writes the voice-agent worker (LiveKit Agents, Python).
Everything below runs from `selfhost/compose.voice.yml` (Compose project `happy-voice`).

```
make voice-up      # start (the LLM takes ~2-3 min to load and compile)
make voice-status  # health of every service + GPU memory
make voice-smoke   # end-to-end check, prints the latencies below
make voice-try     # browser test page on http://127.0.0.1:8899
make voice-logs SVC=stt
```

Config and secrets live in `selfhost/.env.voice` (gitignored; template `.env.voice.example`,
`make voice-keys` generates the LiveKit key pair).

## Service map

| Service | Container | Listens on | Model / image | GPU |
|---|---|---|---|---|
| LiveKit | `happy-voice-livekit` | `127.0.0.1:7880` (HTTP + WS signaling), `*:7881/tcp` (ICE/TCP), `:7882/udp` (single UDP mux, LAN + VPN addresses) | `livekit/livekit-server:v1.13.10`, host networking | none |
| STT | `happy-voice-stt` | `127.0.0.1:8090` | `nvidia/nemotron-speech-streaming-en-0.6b` (NeMo 3.0.0, cache-aware FastConformer RNNT), image built from `selfhost/stt/` | 0 |
| TTS | `happy-voice-tts` | `127.0.0.1:8880` | `ghcr.io/remsky/kokoro-fastapi-gpu:v0.9.0` (Kokoro-82M) | 0 |
| LLM | `happy-voice-llm` | `127.0.0.1:8000` | `vllm/vllm-openai:v0.32.0` serving `QuantTrio/Qwen3.6-35B-A3B-AWQ` as `voice-llm`, TP=2 | 0 + 1 |

Public signaling: `wss://livekit.girthbass.duckdns.org` (host Caddy -> 127.0.0.1:7880).
The router must forward **TCP 7881** and **UDP 7882** to this host for clients outside the LAN.

### GPU map

| GPU | Use | Memory (measured) |
|---|---|---|
| 0 (3090) | STT (~5 GB), TTS (~1 GB), vLLM rank 0 (~16.7 GB) | ~23.5 / 24.6 GB |
| 1 (3090 Ti) | vLLM rank 1 | ~16.9 / 24.6 GB |
| 2, 3 | Taken by a separate, pre-existing vLLM systemd service (`qwen38-27b-fp8-tp2-vllm`) | full |

The plan reserved GPUs 1-2 for the LLM, but GPUs 2 and 3 were already in use, so the LLM shares GPU 0.
vLLM starts only after STT and TTS are healthy and takes `LLM_GPU_MEM_UTIL=0.68` of each GPU, which
leaves about 1 GB of headroom on GPU 0. If GPUs 2-3 are freed, set `LLM_GPU_A=1`, `LLM_GPU_B=2`,
raise `LLM_GPU_MEM_UTIL` to about 0.9 and `make voice-up SVC=llm`.

## LiveKit

- API key/secret: `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` in `.env.voice`.
- Worker URL (same host): `ws://127.0.0.1:7880`. Client URL: `wss://livekit.girthbass.duckdns.org`.
- Health: `GET http://127.0.0.1:7880/` -> `OK`.
- Token: a standard LiveKit JWT (`livekit-api` `AccessToken(...).with_grants(VideoGrants(room_join=True, room=...))`).
- Room settings: `empty_timeout: 300`, `departure_timeout: 20` (`selfhost/livekit.yaml`).

## STT: Nemotron streaming (`http://127.0.0.1:8090`)

No LiveKit plugin speaks to Nemotron directly, so this is a small custom server
(`selfhost/stt/server.py`). The worker needs a thin `stt.STT` subclass with `streaming=True`
that relays audio frames to the websocket below.

### `GET /health`
`200 {"status":"ok","model":"nvidia/nemotron-speech-streaming-en-0.6b","sample_rate":16000,"chunk_ms":160,"att_context_size":[70,1],"device":"cuda"}`; `503 {"status":"loading"}` while the model loads.

### `WS /v1/stream?sample_rate=16000[&endpoint_ms=0][&interim_results=true]`
- **In, binary:** raw PCM16 little-endian, mono, 16 kHz, any frame size (20 ms = 640 bytes is typical). Resample LiveKit's 48 kHz frames before sending (`rtc.AudioResampler`).
- **In, text (JSON control):**
  - `{"type":"flush"}` ends the current segment now. The server pads silence, emits a `final`, and starts a new segment on the same socket. Send this when VAD or the turn detector says the user stopped.
  - `{"type":"reset"}` drops the current segment without emitting a final.
  - `{"type":"close"}` (or `eof`) finalises any pending audio, sends `{"type":"closed"}` and closes.
- **Out (JSON text):**
  - `{"type":"ready","model":...,"sample_rate":16000,"chunk_ms":160}` once, on connect.
  - `{"type":"partial","segment_id":0,"text":"Hey tell Claude to","audio_ms":1440}` whenever the hypothesis changes. `text` is the whole segment so far, not a delta.
  - `{"type":"final","segment_id":0,"text":"...","audio_ms":4960,"flush_ms":81.4}` after `flush`, after `close`, or after an endpoint.
  - `{"type":"error","message":"..."}`.
- `endpoint_ms` > 0 turns on a simple server-side endpoint: a `final` is sent after the transcript has not changed for that many ms of audio. Leave it at 0 when the worker has Silero VAD and the turn detector, and use `flush` instead.
- Output is cased and punctuated. Each socket has its own decoder state; GPU steps from all sockets share one lock, and each step takes about 10-20 ms.
- Latency setting: `STT_RIGHT_CONTEXT` (0 = 80 ms chunks, 1 = 160 ms [default], 6 = 560 ms, 13 = 1120 ms; larger is more accurate).

### `POST /v1/audio/transcriptions` (OpenAI-style)
multipart `file` (any format libsndfile reads; resampled to 16 kHz), optional `response_format=text`.
-> `{"text":"...","duration":4.717,"processing_s":0.12}`. Uses offline (whole-utterance) decoding.

## TTS: Kokoro-FastAPI (`http://127.0.0.1:8880`)

OpenAI-compatible, so it works with `livekit-plugins-openai`'s `openai.TTS(base_url="http://127.0.0.1:8880/v1", api_key="x", model="kokoro", voice="af_heart")`.

### `POST /v1/audio/speech`
```json
{"model":"kokoro","input":"Hello there.","voice":"af_heart","response_format":"pcm","stream":true,"speed":1.0}
```
- `response_format: "pcm"` returns raw PCM16 LE, mono, **24 kHz**, streamed as chunked transfer. `mp3`, `opus`, `wav` and `flac` also work.
- Voices: `GET /v1/audio/voices` -> `{"voices":[{"id":"af_heart",...},...]}`. Good English defaults: `af_heart`, `af_bella`, `am_michael`, `bf_emma`, `bm_george`. Voices can be blended, e.g. `"af_heart+af_bella"`.
- Health: `GET /health`. Built-in UI: `http://127.0.0.1:8880/web`. API docs: `http://127.0.0.1:8880/docs`.

## LLM: vLLM (`http://127.0.0.1:8000/v1`)

OpenAI Chat Completions. Model name **`voice-llm`** (the HF id `QuantTrio/Qwen3.6-35B-A3B-AWQ` also works).
Use `livekit-plugins-openai`'s `openai.LLM(base_url="http://127.0.0.1:8000/v1", api_key="x", model="voice-llm")`.

- Tool calling: `--enable-auto-tool-choice --tool-call-parser qwen3_coder`. Pass `tools` in the standard OpenAI format and get back standard `tool_calls` deltas when streaming.
- Thinking is **off** by default (`--default-chat-template-kwargs '{"enable_thinking": false}'`, with `--reasoning-parser qwen3`). To turn it on for one request, send `"chat_template_kwargs":{"enable_thinking":true}`; any reasoning is then split out of `content` into the reasoning field (`reasoning_content`/`reasoning`, depending on the vLLM version).
- Context: 32768 tokens (`LLM_MAX_MODEL_LEN`). Prefix caching is on, so keep the system prompt stable.
- Health: `GET /health`, `GET /v1/models`.

Tool schema used by the smoke test (copy for the agent):
```json
{"type":"function","function":{"name":"sendMessageToSession",
  "description":"Send a message to a coding agent session on the user's machine.",
  "parameters":{"type":"object","properties":{
    "sessionId":{"type":"string","description":"ID of the target session"},
    "message":{"type":"string","description":"The message to send, phrased as an instruction to the coding agent"}},
  "required":["sessionId","message"]}}}
```
Result: `sendMessageToSession({"sessionId":"sess_42","message":"List the files in the src directory."})`.

## Measured latencies (2026-10-25, all services sharing the box, single request)

| Stage | Result |
|---|---|
| LiveKit token join, local `ws://127.0.0.1:7880` | 0.7 s to connect, then 3 ms to publish an audio track |
| LiveKit token join + publish via `wss://livekit.girthbass.duckdns.org` | 1.0 s |
| TTS time to first audio byte (streamed PCM) | 106-165 ms, flat from 1 to 20 sentences |
| TTS throughput | 105.6 s of audio in 1.35 s (RTF ~0.013) |
| STT partial lag behind real-time audio | avg 55 ms, max 82 ms (160 ms chunks) |
| STT final after `flush` (end of audio) | ~80-110 ms |
| STT accuracy on TTS sample | 0% WER streaming |
| STT whole file (4.7 s) | 144 ms |
| LLM time to first token (71-token prompt) | 81 ms |
| LLM tool call: first delta / complete | 272 ms / 507 ms |
| LLM decode speed | ~168 tok/s |

So the expected service time from end of speech to first audio is roughly STT final (~100 ms) +
LLM time to the first sentence (~150-300 ms) + TTS first byte (~140 ms), plus the turn detector's
end-of-turn delay. The `make voice-try` page's Chat section measures this end to end in a browser.

## Test page (`make voice-try`)

`selfhost/voice-test/` is an aiohttp server bound to **127.0.0.1:8899 only**. It serves `index.html` and proxies
`/api/tts/voices`, `/api/tts/speech`, `/api/stt/health`, `/api/stt/stream` (WS) and `/api/llm/chat`
so a single tunnel is enough: `ssh -L 8899:127.0.0.1:8899 prep@<host>`, then open `http://localhost:8899`
(localhost counts as a secure context, so the microphone works).
