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
| `TTS_MODEL` | prince-canuma/Kokoro-82M | a directory holding a Kokoro model and a `voices/` folder, or anything else, which is resolved against Hugging Face |
| `TTS_VOICE` | af_heart | default voice |
| `TTS_FAST_FIRST` | 1 | split the first sentence at a clause, a conjunction or `TTS_FIRST_MAX_WORDS`, so audio starts sooner |
| `TTS_FIRST_MAX_WORDS` | 8 | hard cap on the first piece when there is no clause or conjunction to split at. Lower starts sooner but inserts a gap — see below |
| `TTS_FIRST_MIN_WORDS` | 3 | floor on the first piece, so it never becomes a one- or two-word fragment |
| `TTS_TRIM_PIECES` | 1 | drop each piece's silent lead and cut its tail to `TTS_PAUSE` — see below |
| `TTS_PAUSE` | 0.20 | seconds of silence kept between pieces |
| `TTS_MP3_KBPS` | 96 | bitrate of the streamed mp3 |

`install-service.sh` writes `TTS_MODEL`, `TTS_VOICE` and `TTS_FIRST_MAX_WORDS` into the launchd
plist, so they survive a reinstall and a reboot. Anything set only in a shell does not. Editing
the plist afterwards is not enough on its own either: launchd keeps the job it loaded, so a
`launchctl kickstart` restarts the service with the old environment. Reload it instead —
`launchctl bootout gui/$(id -u)/com.happy.voice-tts` then `launchctl bootstrap gui/$(id -u)
~/Library/LaunchAgents/com.happy.voice-tts.plist` — or just re-run the installer.

## A fine-tuned Kokoro

Point `TTS_MODEL` at a directory that holds the model weights and a `voices/` folder of
`*.safetensors` voice packs. A path that is not an existing directory is treated as a Hugging Face
repo id instead, so the default needs no local files. Custom voices are resolved from that
`voices/` folder first, which is why a voice that exists nowhere on the hub still works.

```sh
TTS_MODEL=$HOME/kokoro-am-morgan TTS_VOICE=am_morgan ./install-service.sh
```

`GET /v1/audio/voices` lists what was found and `GET /health` echoes the model that is loaded.
Check both after a reinstall, because a `TTS_MODEL` directory that does not exist is not an
error: it falls through to the hub and serves stock Kokoro.

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

### Padding, and the stops it caused

Every Kokoro synthesis pads its audio. Measured on an M1, "I have sent that" holds speech from
0.36 s to 1.00 s of a 1.38 s buffer, and "that along." from 0.46 s to 0.76 s of another 1.38 s.
That is harmless for one piece but not for two: the text above runs 2.35 s whole and 3.52 s split,
with a **0.84 s hole where the pieces join** — audible as a stop in the middle of a sentence, or
between sentences in a longer reply, since every sentence is its own piece. `af_heart` showed the
same 0.80 s gap, so it is the model and not a voice pack.

So each piece is trimmed before it is sent: the speech-free lead is dropped, and the tail is cut
back to `TTS_PAUSE` (0.20 s), which is the spacing between sentences. The thresholds come from the
voice agent's `happy_voice/tts_trim.py`, which derived them by sweep — speech is 50 ms held at
rms 1012, and the cut goes to the end of the quiet stretch in front of it, found by search rather
than set by the threshold, so both ways of being wrong keep audio instead of clipping a word.

| | before | after |
|---|---|---|
| "I have sent that along." | 3.52 s, 0.84 s hole | 1.45 s, no gap |
| 9-word sentence | 4.83 s | 3.13 s |
| 22-word sentence | 10.55 s, 1.00 s hole at the join | 8.85 s, no gap |
| speech starts | 940 ms into the audio | 60 ms |
| cost | | 0.2–0.8 ms per piece |

Time to first byte is unchanged — the trim runs on a piece that is already synthesized — but the
first audible word arrives about 880 ms sooner, because what used to play first was the lead.
`TTS_TRIM_PIECES=0` turns it off.

### What the cap costs

With the padding gone, `TTS_FIRST_MAX_WORDS` is a plain trade of latency against phrasing: each
piece is synthesized on its own, so its intonation restarts, and a split mid-phrase sounds it.
Time to the first audible word, `am_morgan` over the LAN, median of three warm runs:

| Cap | 9-word sentence, no conjunction | 22-word sentence |
|---|---|---|
| 4 | 550 ms | 676 ms |
| 6 | 667 ms | 677 ms |
| 8 (default) | 713 ms | 681 ms |
| 12 | 722 ms | 640 ms |
| `TTS_FAST_FIRST=0` | 743 ms | 1543 ms |

So raising the cap costs little — about 160 ms between 4 and 8 on a short sentence, and nothing
at all on a long one, where the first split lands on a conjunction before the cap applies.
Turning splitting off is the one setting that hurts: 1543 ms on the long sentence.

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
