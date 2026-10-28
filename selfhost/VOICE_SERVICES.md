# Voice services contract

This document is for whoever writes the voice-agent worker (LiveKit Agents, Python).
Everything below runs from `selfhost/compose.voice.yml` (Compose project `happy-voice`).

```
make voice-up      # start livekit, stt, tts and the voice-agent worker
make voice-agent-up   # rebuild/restart only the worker
make voice-agent-e2e  # headless fake-app conversation against the running worker
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
| LiveKit | `happy-voice-livekit` | `127.0.0.1:7880` (HTTP + WS signaling, published for the agent); 7881/tcp and 7882/udp (UDP mux) only on the container IP | `livekit/livekit-server:v1.13.10`, on the `happy-selfhost_default` network (alias `livekit`) | none |
| STT | `happy-voice-stt` | `127.0.0.1:8090` | `nvidia/nemotron-speech-streaming-en-0.6b` (NeMo 3.0.0, cache-aware FastConformer RNNT), image built from `selfhost/stt/` | 0 |
| TTS | `happy-voice-tts` | `127.0.0.1:8880` | `ghcr.io/remsky/kokoro-fastapi-gpu:v0.9.0` (Kokoro-82M) | 1 |
| LLM | host systemd `qwen38-27b-fp8-tp2-vllm` (not managed here) | `127.0.0.1:9080` | Qwen3.8-27B FP8 served as `coder`, TP=2 | 2 + 3 |
| Voice agent | `happy-voice-agent` | `127.0.0.1:8791` (health) | `packages/happy-voice-agent` (LiveKit Agents 1.8.9), host networking | none (CPU) |
| LLM (optional, profile `local-llm`) | `happy-voice-llm` | `127.0.0.1:8000` | `vllm/vllm-openai:v0.32.0` serving `QuantTrio/Qwen3.6-35B-A3B-AWQ` as `voice-llm`, TP=2 | 0 + 1 |

LiveKit has no public endpoint. Apps stream audio to happy-server (`wss://happy.girthbass.duckdns.org/v1/voice/stream`,
protocol in `packages/happy-wire/src/voiceStream.ts`), which joins the room over the docker network
(`ws://livekit:7880`). No router forwards, ufw rules or Caddy site are needed for voice.

### GPU map

| GPU | Use | Memory (measured) |
|---|---|---|
| 0 (3090) | STT (~1.6 GB in bf16; was ~5.1 GB in fp32) | ~1.6 / 24.6 GB |
| 1 (3090 Ti) | TTS (~1.5 GB) | ~1.5 / 24.6 GB |
| 2, 3 | Taken by a separate, pre-existing vLLM systemd service (`qwen38-27b-fp8-tp2-vllm`) | full |

The voice LLM is now the host's existing `coder` vLLM on GPUs 2-3 (systemd; never restarted or
reconfigured from here). The old local voice LLM (`vllm-openai`, ~16.9 GB on each of GPUs 0 and 1) is
retired and runs only when started on purpose: it sits behind the compose profile `local-llm`, so `make voice-up` no longer
starts it. Opt in with `make voice-up SVC=llm` (or `--profile local-llm`), then point
`VOICE_LLM_BASE_URL=http://127.0.0.1:8000/v1` and `VOICE_LLM_MODEL=voice-llm` at it. It starts only
after STT and TTS are healthy and takes `LLM_GPU_MEM_UTIL=0.68` of each GPU, which leaves room
for the ~1.6 GB STT holds on GPU 0 and the ~1.5 GB TTS holds on GPU 1. The `vllm-cache`
volume and weights are kept.

STT and TTS are deliberately on different GPUs (`STT_GPU=0`, `TTS_GPU=1`). The STT server takes
one global GPU lock per 10-20 ms streaming step, so when Kokoro shared the device its synthesis
bursts queued behind those steps and reply chunks arrived late enough to sound choppy.

## LiveKit

- API key/secret: `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` in `.env.voice`.
- Worker URL (same host): `ws://127.0.0.1:7880`. happy-server: `ws://livekit:7880` (`LIVEKIT_URL`). No client URL.
- Health: `GET http://127.0.0.1:7880/` -> `OK`.
- Token: a standard LiveKit JWT (`livekit-api` `AccessToken(...).with_grants(VideoGrants(room_join=True, room=...))`).
- Room settings: `empty_timeout: 300`, `departure_timeout: 20` (`selfhost/livekit.yaml`).

## STT: Nemotron streaming (`http://127.0.0.1:8090`)

No LiveKit plugin speaks to Nemotron directly, so this is a small custom server
(`selfhost/stt/server.py`). The worker needs a thin `stt.STT` subclass with `streaming=True`
that relays audio frames to the websocket below.

### `GET /health`
`200 {"status":"ok","model":"nvidia/nemotron-speech-streaming-en-0.6b","sample_rate":16000,"chunk_ms":160,"att_context_size":[70,1],"device":"cuda","dtype":"bf16"}`; `503 {"status":"loading"}` while the model loads.

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
- Precision: `STT_DTYPE` (`bf16` [default] or `fp32`). bf16 runs the conformer encoder in bfloat16; the
  mel preprocessor and the RNNT decoder + joint stay in fp32. VRAM per process (nvidia-smi): about
  1.6 GB in bf16 against 2.8 GB in fp32 (5.1 GB before the model was loaded on the CPU first and the
  allocator was set to `expandable_segments`), unchanged with two concurrent streams. On 24 Kokoro clips
  (12 coding sentences, 6 voices, 134 s) bf16 and fp32 give word-for-word identical transcripts
  (2.2% WER streaming and file) with the same latency.

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

## LLM: vLLM (`VOICE_LLM_BASE_URL`, default `http://127.0.0.1:9080/v1`)

OpenAI Chat Completions. Default model **`coder`** (host service, no API key, `MAX_SEQS=2`, so keep
`max_tokens` modest; the worker uses 250). Configure with `VOICE_LLM_BASE_URL` / `VOICE_LLM_MODEL` in
`.env.voice`; the worker, `voice-status` and `voice-smoke` all read them. Always send
`"chat_template_kwargs":{"enable_thinking":false}`. The notes below describe the optional local
`voice-llm` (`http://127.0.0.1:8000/v1`); tool calling and thinking work the same way on `coder`.
Both Qwen chat templates reject a system message that is not first, so the worker folds later system
context into user messages.

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
| TTS time to first audio byte (streamed PCM) | 106-165 ms, flat from 1 to 20 sentences |
| TTS throughput | 105.6 s of audio in 1.35 s (RTF ~0.013) |
| STT partial lag behind real-time audio | avg 55 ms, max 82 ms (160 ms chunks); bf16 2026-10-26: avg 43 ms, max 64 ms |
| STT final after `flush` (end of audio) | ~80-110 ms; bf16 2026-10-26: avg 95 ms, max 114 ms |
| STT accuracy on TTS sample | 0% WER streaming |
| STT whole file (4.7 s) | 144 ms |
| LLM time to first token (71-token prompt) | 81 ms |
| LLM tool call: first delta / complete | 272 ms / 507 ms |
| LLM decode speed | ~168 tok/s |

With `coder` (2026-10-26): first token ~150-600 ms, tool call first delta / complete 614 / 848 ms,
~77 tok/s decode, occasional multi-second stalls when both of its `MAX_SEQS=2` slots are busy.

Full conversation, `make voice-agent-e2e` (fake app, Kokoro speech in, end of user speech -> first
agent audio, including VAD silence 0.5 s and the turn detector): p50 1.84-2.11 s, max 2.46 s over
3 runs on `coder` (tool turns ~1.7-1.9 s because the app's scripted tool replies are spoken without a
second LLM call). On the old local `voice-llm` it was p50 ~1.4 s with VAD silence 0.35 s.

So the expected service time from end of speech to first audio is roughly STT final (~100 ms) +
LLM time to the first sentence (~150-300 ms) + TTS first byte (~140 ms), plus the turn detector's
end-of-turn delay. The `make voice-try` page's Chat section measures this end to end in a browser.

## Test page (`make voice-try`)

`selfhost/voice-test/` is an aiohttp server bound to **127.0.0.1:8899 only**. It serves `index.html` and proxies
`/api/tts/voices`, `/api/tts/speech`, `/api/stt/health`, `/api/stt/stream` (WS) and `/api/llm/chat`
so a single tunnel is enough: `ssh -L 8899:127.0.0.1:8899 prep@<host>`, then open `http://localhost:8899`
(localhost counts as a secure context, so the microphone works).
