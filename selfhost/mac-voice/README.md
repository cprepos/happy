# mac-voice: local STT and TTS on Apple Silicon

Speech-to-text and text-to-speech services for an M-series Mac. They use the same models and API
shapes as the selfhost GPU services (`selfhost/stt`, Kokoro-FastAPI), so a client can point at
either one. MLX does all the work on the Mac. Nothing here runs an LLM.

| Service | Port | Model | Endpoints |
|---|---|---|---|
| STT | 8090 | `nvidia/nemotron-speech-streaming-en-0.6b` (mlx-audio port, fp16 encoder) | WS `/v1/stream` (partial/final JSON), `POST /v1/audio/transcriptions`, `GET /health` |
| TTS | 8880 | Kokoro-82M (`prince-canuma/Kokoro-82M`, mlx-audio), voice `af_heart` | `POST /v1/audio/speech` (pcm, wav and mp3 stream; flac and opus are sent whole), `GET /v1/audio/voices`, `GET /v1/models`, `GET /health` |

## Setup and start

Copy this directory to `~/happy-voice-local` on the Mac, then:

```sh
cd ~/happy-voice-local
./run.sh setup     # uv into ~/.local/bin (no shell profile edits), Python 3.12, .venv, pinned requirements
./run.sh start     # both services in the background; waits for /health (about 5 s each once models are cached)
./run.sh status    # health and memory
./run.sh stop
```

By default both services bind `127.0.0.1`. To reach them from another machine, use an SSH tunnel:

```sh
ssh -N -L 8090:127.0.0.1:8090 -L 8880:127.0.0.1:8880 prep-air
```

The other option is `install-service.sh`. It installs launchd user agents that bind `VOICE_HOST`
(0.0.0.0 in the installer) and adds a pf rule that only lets `ALLOW_FROM` connect. Once these are
installed, `run.sh start|restart` goes through `launchctl kickstart`.

The models download into the Hugging Face cache on first start: Nemotron 0.6B is 2.5 GB and
Kokoro-82M with its voices is 0.34 GB. The `.venv` takes another 1.4 GB.

## Settings (environment)

| Variable | Default | Meaning |
|---|---|---|
| `STT_PORT` / `TTS_PORT` | 8090 / 8880 | ports |
| `VOICE_HOST` | 127.0.0.1 | bind address |
| `WARMUP` | 1 | run one inference at load, so the first request is not cold |
| `STT_BACKEND` | nemotron | `parakeet` uses `mlx-community/parakeet-tdt-0.6b-v3` with a streaming context of `STT_PARAKEET_CONTEXT` (128,16) |
| `STT_RIGHT_CONTEXT` | 6 | Nemotron look-ahead for streaming: 0/1/6/13 gives 80/160/560/1120 ms. 6 matches the server |
| `STT_FILE_RIGHT_CONTEXT` | 13 | look-ahead for `/v1/audio/transcriptions`. 13 is about 6x faster than 1 on an M1 |
| `STT_DTYPE` | fp16 | encoder dtype. fp16 costs about 49 ms per 160 ms chunk on an M1, bf16 about 55 ms, fp32 about 70 ms. q8, q4 and `mx.compile` gave nothing |
| `STT_ENDPOINT_MS` | 0 | silence that ends an utterance when the client does not set it |
| `TTS_VOICE` | af_heart | default voice |
| `TTS_FAST_FIRST` | 1 | split the first sentence at a clause, a conjunction or `TTS_FIRST_MAX_WORDS` (8), so audio starts sooner |
| `TTS_MP3_KBPS` | 96 | bitrate of the streamed mp3 |

## Why the TTS splits the first sentence

On an M1 the Kokoro iSTFTNet vocoder is about 85% of the synthesis time: roughly 100 ms per call
plus 90 ms per second of audio. That means time to first byte grows with the length of the first
chunk. These alternatives were measured and none of them was faster:

| Alternative | Short / 7 s sentence (warm, in-process) |
|---|---|
| kokoro-mlx 0.1.4 | 225 / 786 ms |
| mlx-audio bf16, 8-bit and 4-bit | 208–211 / 784–821 ms |
| kokoro-onnx on CPU | ~700 / ~3200 ms |
| kokoro-onnx on CoreML | ~950 / ~3900 ms |

The default fp32 mlx-audio model is 214 / 818 ms. Splitting the first sentence cut the medium
sentence's time to first byte from about 900 ms to about 390 ms. The rest of the text is
synthesized while the first piece plays, since generation runs at RTF ~0.13.

## Results (MacBook Air M1, 16 GB, macOS 15.7.4, on AC power, Low Power Mode off)

Benchmarks are run with `bench.py` (`stt`, `tts`, `files`, `idle`, `sustained`), using the same 24
clips (362 words) as the server benchmark. Results go to `bench/results/`.

| | Mac M1 (this) | Server GPU |
|---|---|---|
| TTS first byte, short (1.5 s audio) | 236 ms p50 | 100–165 ms |
| TTS first byte, medium / long / 95 s paragraph | 388 / 329 / 327 ms | 106–165 ms |
| TTS RTF | 0.12–0.15 | ~0.013 |
| TTS cold first request (WARMUP=0) | 3.5 s, then warm | — |
| STT partial lag (160 ms chunks) | mean 44, p95 55, max 63 ms | mean 43, max 64 ms |
| STT final after flush | mean 100, p50 89, max 149 ms | ~95 ms (max 114) |
| STT WER, streaming | 2.21% | 2.21% |
| STT WER / speed, file (`/v1/audio/transcriptions`) | 2.49%, RTF 0.066 (300–540 ms per clip) | 2.21%, 144 ms for 4.7 s |
| Memory, idle with both loaded | 2.26 GB footprint (STT 1.24 GB + TTS 0.31 GB MLX active) | ~1.6 GB + ~1.5 GB VRAM |
| Memory, peak under load | STT 1.9 GB, TTS 1.9–3.5 GB footprint | — |
| Startup | ~5 s per service with cached models | — |

Sustained test: 5 minutes of real-time streaming STT (48 utterances) with a TTS request every 20 s
(14 requests). Results stayed flat from minute to minute:

- STT lag averaged 52–55 ms and finals 127–142 ms.
- STT WER was 2.21%.
- TTS first byte was 395–498 ms, because both services share the GPU.
- `pmset -g therm` recorded no thermal or performance warning at any point, with no CPU speed limit.
- The battery charged from 58% to 63% during the run.

Other file-transcription models, run in-process with `bench.py files`:

| Model | WER | RTF | MLX peak |
|---|---|---|---|
| whisper-large-v3-turbo (mlx-whisper) | 0.00% | 0.257 | 2.0 GB |
| parakeet-tdt-0.6b-v3 | 1.93% | 0.037 | 3.2 GB |
| parakeet-tdt-0.6b-v2 | 1.38% | 0.035 | 3.2 GB |

Notes:

- macOS process RSS leaves out Metal buffers. The memory figures above come from `footprint` and
  from MLX's own counters (`/health`).
- Timings vary when Spotlight indexing (`mds_stores`) is busy. Early runs during indexing showed a
  short-input TTS first byte of 360 ms and STT partial-lag spikes up to 0.9 s.
