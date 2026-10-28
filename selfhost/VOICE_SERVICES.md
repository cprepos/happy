# Voice services contract

This document is for whoever writes the voice-agent worker (LiveKit Agents, Python).
Everything below runs from `selfhost/compose.voice.yml` (Compose project `happy-voice`).

```
make voice-up      # start livekit, stt, tts and the voice-agent worker
make voice-agent-up   # rebuild/restart only the worker
make voice-agent-e2e  # headless fake-app conversation against the running worker
make voice-status  # health of every service + GPU memory
make voice-smoke   # end-to-end check, prints the latencies below
make voice-try     # browser test page on http://127.0.0.1:8897
make voice-logs SVC=stt
```

Config and secrets live in `selfhost/.env.voice` (gitignored; template `.env.voice.example`,
`make voice-keys` generates the LiveKit key pair).

## Service map

| Service | Container | Listens on | Model / image | GPU |
|---|---|---|---|---|
| LiveKit | `happy-voice-livekit` | `127.0.0.1:7880` (HTTP + WS signaling, published for the agent); 7881/tcp and 7882/udp (UDP mux) only on the container IP | `livekit/livekit-server:v1.13.10`, on the `happy-selfhost_default` network (alias `livekit`) | none |
| STT | `happy-voice-stt` | `127.0.0.1:8090` | `nvidia/nemotron-speech-streaming-en-0.6b` (NeMo 3.0.0, cache-aware FastConformer RNNT), image built from `selfhost/stt/` | 0 |
| TTS | `happy-voice-tts` | `127.0.0.1:8880` | `ghcr.io/remsky/kokoro-fastapi-gpu:v0.9.0` (Kokoro-82M) | 0 |
| LLM | host coder stack (systemd, not managed here) | `127.0.0.1:9081` (the tier voice is pinned to) | Qwen3.6-35B-A3B int4 served as `coder-moe`; see the LLM section for the other tiers | shared |
| Voice agent | `happy-voice-agent` | `127.0.0.1:8791` (health) | `packages/happy-voice-agent` (LiveKit Agents 1.8.9), host networking | none (CPU) |
| LLM (optional, profile `local-llm`) | `happy-voice-llm` | `127.0.0.1:8000` | `vllm/vllm-openai:v0.32.0` serving `QuantTrio/Qwen3.6-35B-A3B-AWQ` as `voice-llm`, TP=2 | 0 + 1 |

LiveKit has no public endpoint. Apps stream audio to happy-server (`wss://happy.girthbass.duckdns.org/v1/voice/stream`,
protocol in `packages/happy-wire/src/voiceStream.ts`), which joins the room over the docker network
(`ws://livekit:7880`). No router forwards, ufw rules or Caddy site are needed for voice.

### GPU map

| GPU | Use | Memory (measured) |
|---|---|---|
| 0 (3090) | STT (~1.6 GB in bf16) + TTS (~1.0 GB) -- both, since 2026-10-28 (`STT_GPU` / `TTS_GPU`) | ~2.6 GB of 24.6 GB, GPU 0 ~13.4 GB used in all |
| 1 (3090 Ti) | no voice work | free for other services |
| 2, 3 | the dense coder vLLM (`coder-dense`, TP=2) | full |

TTS on GPU 0 measured no slower than on its own GPU (TTFB 111-165 ms either way).

The voice LLM is a tier of the host's coder stack (systemd; never restarted or reconfigured from
here). The old local voice LLM (`vllm-openai`, ~16.9 GB on each of GPUs 0 and 1) is
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
- Latency setting: `STT_RIGHT_CONTEXT` (0 = 80 ms chunks, 1 = 160 ms [default], 6 = 560 ms, 13 = 1120 ms).
  A 90-clip benchmark (3 voices, 3 SNRs) found 1/6/13 within noise of each other -- WER 5.39 / 5.23 /
  5.10 %, median 0.00 % at all three, and 6 *worse* than 1 at 10 dB -- so 1 takes the ~400 ms that 6
  adds to every emission.
  The checkpoint ships these four and no others; NeMo's own default is 13. Larger look-ahead is
  billed on *every* emission, not just the last one: the encoder cannot emit a token until that
  many frames have arrived, so 6 adds ~400 ms and 13 ~960 ms before the turn detector even sees
  the transcript.

  Measured here (90 clips, 3 voices, clean/20 dB/10 dB, each streamed in real time through its own
  STT container): WER mean 5.39% at rc=1, 5.23% at rc=6, 5.10% at rc=13 — median 0.00% at all three,
  and the per-SNR split shows the spread is noise (rc=13 ties rc=1 at 20 dB; rc=6 is worse than rc=1
  at 10 dB). What is left at every setting is acoustic substitution, not truncation: "push it to main"
  → "push it to Maine", "stop for a second" → "stop the second". No first- or last-word loss at any
  setting, because `_finish()` in `stt/server.py` pads the tail by one full chunk — which is also why
  NeMo issue #16310 (cache-aware streaming dropping a short final chunk) does not reach us.

  So accuracy is not the reason for the default; 6 is set deliberately, and 1 is the setting to go
  back to if the added latency is felt in conversation.
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

### The silent lead, and why the agent trims it

For some inputs Kokoro returns about 0.7 s of speech-free audio *before* the speech: a burst
rising to roughly rms 99 within 100 ms, then decaying to zero over half a second (peak ~2% of
full scale). It is deterministic per text and, measured across 12 texts, appears only with the
fine-tuned `am_morgan` voice -- `af_heart` (50-64 ms of lead) and `bm_george` (50-59 ms) never
show it. Since the fine-tuned `kokoro-v1_0.pth` is mounted for every voice, the artifact belongs
to the `am_morgan.pt` voice pack, not the model weights. A Kokoro voice pack is a table of style
vectors indexed by the input's phoneme count, so a pack with poorly conditioned low rows misfires
on exactly the short inputs the agent sends.

That matters more than it sounds, because `StreamAdapter` issues one synthesize request per
sentence batch and the pacer's first batch is always a single sentence. So the artifact lands at
the start of every reply, and often every sentence: one four-sentence reply measured 7.907 s as a
single direct request against 8.825 s through the pipeline.

The region carries no speech at all -- our own STT transcribes it as `""` even amplified 24x -- so
`happy_voice/tts_trim.py` in the voice agent drops it, keeping a 30 ms pad with a 5 ms fade-in.
The onset threshold (rms 180 over a 10 ms window) sits between the loudest artifact window
measured, 133, and the quietest speech onset, 235; anything the search cannot positively identify
as pre-speech is passed through whole. Set `TTS_TRIM_LEAD=0` to disable it. The real fix is to
re-extract `am_morgan.pt` from clean reference clips in the `mf-morgan` project; the trimmer is
voice-agnostic and costs nothing once that happens.

## LLM: vLLM (`VOICE_LLM_BASE_URL`, default `http://127.0.0.1:9081/v1`)

OpenAI Chat Completions. The host's coder stack was split into two tiers behind a gateway on
2026-10-28:

| Port | Served name | Model | Notes |
|---|---|---|---|
| 9080 | `coder-dense` | Qwen3.8-27B FP8, TP=2 | what plain `coder` used to be; ~90 tok/s decode |
| 9081 | `coder-moe` | Qwen3.6-35B-A3B int4 (~3B active), `--max-num-seqs 1` | ~178 tok/s decode; **voice is pinned here** |
| 8899 | `coder` (virtual) | agentgateway + the `vllm-sr-router` ExtProc classifier on gRPC 50051 | classifies each turn onto a tier |

Default model **`coder-moe`** (host service, no API key; keep `max_tokens` modest -- the worker uses
250). Voice is pinned to one tier rather than pointed at the virtual `coder`, because that gateway
routes statelessly per turn: the prefix warm-up (`happy_voice/warmup.py`) could warm a tier the turn
never lands on, and a tier switch costs a full prefill. `coder-moe` is the pick because voice latency
is decode-bound. Watch its `--max-num-seqs 1`: warm-up and turn cannot overlap at all there, and a
coding agent on that tier blocks voice outright -- `WARMUP_TURN_WAIT` (0.5 s) is what keeps that from
becoming a mute agent.

**The name `coder` alone now 404s on both tier ports.** When a turn fails with
`The model 'coder' does not exist` and the user reports "STT not working", this is why -- the STT is
fine and the agent simply has no LLM to answer with.

Configure with `VOICE_LLM_BASE_URL` / `VOICE_LLM_MODEL` in `.env.voice`; the worker, `voice-status`
and `voice-smoke` all read them. `.env.voice`'s plain `LLM_MODEL` / `LLM_SERVED_NAME` belong to the
opt-in `local-llm` container and the agent ignores them. Always send
`"chat_template_kwargs":{"enable_thinking":false}`. The notes below describe the optional local
`voice-llm` (`http://127.0.0.1:8000/v1`); tool calling and thinking work the same way on the coder
tiers.
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

With `coder-dense` (2026-10-28): tool call first delta 622 ms, ~90 tok/s decode, occasional
multi-second stalls when both of its `MAX_SEQS=2` slots are busy.

With `coder-moe` (2026-10-28): ~178 tok/s decode, and tool calls do work on the int4 tier. A cold
prefix cache is expensive there -- the first tool call measured an 11.5 s first delta -- so the
warm-up matters more, not less. `make voice-agent-e2e`: 14/14, p50 first audio 1959 ms over four
turns (`coder-dense` the same day: 2083 ms).

Full conversation, `make voice-agent-e2e` (fake app, Kokoro speech in, end of user speech -> first
agent audio, including VAD silence 0.5 s and the turn detector): p50 1.84-2.11 s, max 2.46 s over
3 runs on `coder` (tool turns ~1.7-1.9 s because the app's scripted tool replies are spoken without a
second LLM call). On the old local `voice-llm` it was p50 ~1.4 s with VAD silence 0.35 s.

So the expected service time from end of speech to first audio is roughly STT final (~100 ms) +
LLM time to the first sentence (~150-300 ms) + TTS first byte (~140 ms), plus the turn detector's
end-of-turn delay. The `make voice-try` page's Chat section measures this end to end in a browser.

## Test page (`make voice-try`)

`selfhost/voice-test/` is an aiohttp server bound to **127.0.0.1:8897 only** (`VOICE_TRY_PORT`; it
was 8899 until the host's agentgateway took that port). It serves `index.html` and proxies
`/api/tts/voices`, `/api/tts/speech`, `/api/stt/health`, `/api/stt/stream` (WS) and `/api/llm/chat`
so a single tunnel is enough: `ssh -L 8897:127.0.0.1:8897 prep@<host>`, then open `http://localhost:8897`
(localhost counts as a secure context, so the microphone works).
