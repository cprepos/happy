# Self-hosted Happy

Run your own Happy server, voice assistant, CLI agent, and iOS/web app — no
cloud dependencies. Everything runs on your LAN.

## What you get

| Component | What it does | Runs on |
|---|---|---|
| **happy-server** + Postgres | API server, WebSocket sync, voice relay | Any Linux box (Docker) |
| **happy-cli** | Agent daemon (Claude, OpenCode, etc.) | Same Linux box or any machine with Claude Code |
| **Webapp** | Browser client at your server URL | Built and served by happy-server |
| **iOS app** | Native iPhone client (sideloaded, free signing) | Built on a Mac, installed over Wi-Fi |
| **Voice pipeline** | STT → LLM → TTS, real-time over WebSocket | GPU Linux box (Docker) or Apple Silicon Mac |

## Architecture

```
iPhone / Browser
      │ wss
      ▼
  happy-server ◄─── happy-cli (agent sessions)
      │
      ▼
  LiveKit room
      │
      ▼
  voice-agent ──► STT (Nemotron) ──► LLM (vLLM / any OpenAI-compat) ──► TTS (Kokoro)
```

Apps never connect to LiveKit directly. They stream audio to happy-server
(`/v1/voice/stream`), which joins the LiveKit room on their behalf.

## Quick start

### 1. Server + database

```sh
cd selfhost
make env          # generates .env with random secrets (edit PUBLIC_URL)
make up           # starts Postgres + happy-server on 127.0.0.1:3005
make status       # verify
```

Put a reverse proxy (Caddy, nginx) in front of port 3005 with TLS for your
domain. Example with Caddy:
```
happy.yourdomain.com {
    reverse_proxy 127.0.0.1:3005
}
```

### 2. CLI agent

```sh
cd selfhost
make cli-install  # see cli.mk for details
```

Or manually: install `happy-cli` from the monorepo, point it at your server URL,
and register it. It connects over WebSocket and appears as a "machine" in the app.

### 3. Webapp

```sh
cd selfhost
make webapp-build   # builds the webapp into selfhost/webapp/
# Restart the server to pick it up:
make down && make up
```

The server serves the webapp at its root URL when `selfhost/webapp/index.html` exists.

### 4. Voice (choose one path)

#### Option A: GPU Linux box (recommended for low latency)

Requires an NVIDIA GPU with ≥8 GB VRAM for STT + TTS (a single 3090 works).
An LLM needs its own GPU(s) or you can point at any OpenAI-compatible endpoint.

```sh
cd selfhost
cp .env.voice.example .env.voice   # edit GPU indices, HF cache dir, LLM endpoint
make voice-keys                     # generates LiveKit API key pair
# Copy the key pair into both .env and .env.voice (LIVEKIT_API_KEY / LIVEKIT_API_SECRET)
make voice-up                       # starts LiveKit, STT, TTS, and the voice agent
make voice-status                   # verify all services
make voice-smoke                    # end-to-end latency test
```

Services:
- **STT**: Nemotron 0.6B streaming (CUDA), port 8090
- **TTS**: Kokoro-82M via Kokoro-FastAPI (CUDA), port 8880
- **LiveKit**: room server, port 7880
- **Voice agent**: LiveKit Agents worker, port 8791

See `VOICE_SERVICES.md` for the full contract (endpoints, protocols, latency numbers).

#### Option B: Apple Silicon Mac (no GPU box needed)

Runs STT and TTS on the Mac's GPU via MLX. Good enough for a single user —
latency is ~2-3x higher than CUDA but still real-time. You still need an LLM
somewhere (a cloud API, or a local model on another machine).

```sh
# On the Mac:
cp -r selfhost/mac-voice ~/happy-voice-local
cd ~/happy-voice-local
./run.sh setup      # installs uv, Python 3.12, .venv, dependencies
./run.sh start      # starts STT (port 8090) and TTS (port 8880)
./run.sh status     # verify health + memory
```

Models download on first start: Nemotron 0.6B (2.5 GB) + Kokoro-82M (0.34 GB).
Idle memory: ~2.3 GB. Requires macOS 14+ and an M1 or later.

By default services bind to 127.0.0.1. To expose on the LAN:

```sh
# Option 1: SSH tunnel from your server
ssh -N -L 8090:127.0.0.1:8090 -L 8880:127.0.0.1:8880 your-mac

# Option 2: launchd services with firewall (recommended for always-on)
./install-service.sh   # installs launchd agents, binds 0.0.0.0, adds pf rules
```

The `install-service.sh` script creates launchd user agents with `KeepAlive` and
a pf firewall rule that only allows connections from a specific IP (`ALLOW_FROM`).
Edit the script to set your server's IP before running.

Then point your voice agent at the Mac's IP:
```env
# In selfhost/.env.voice
STT_HOST=192.168.x.x   # your Mac's LAN IP
TTS_HOST=192.168.x.x
```

See `mac-voice/README.md` for benchmarks, tuning, and troubleshooting.

#### Kokoro TTS details

Kokoro is a lightweight (82M parameter) text-to-speech model that produces
natural-sounding speech. It runs on both CUDA and Apple Silicon (via MLX).

- **GPU path**: runs as a Docker container via `ghcr.io/remsky/kokoro-fastapi-gpu:v0.9.0`.
  First byte in ~100-165 ms, RTF ~0.013. Needs ~1.5 GB VRAM.
- **Mac path**: runs as a Python server using `mlx-audio`. First byte in ~236-390 ms,
  RTF ~0.12-0.15. Needs ~0.3 GB MLX memory idle, up to 3.5 GB peak.
- **API**: OpenAI-compatible (`POST /v1/audio/speech`), supports PCM, WAV, MP3, FLAC, Opus
  streaming. Works with `livekit-plugins-openai` out of the box.
- **Voices**: `GET /v1/audio/voices` lists available voices. Defaults: `af_heart`, `af_bella`,
  `am_michael`, `bf_emma`, `bm_george`. Voices can be blended: `"af_heart+af_bella"`.
- **Config**: `TTS_VOICE` (default voice), `TTS_SPEED` (rate multiplier), `TTS_PORT`.

#### Nemotron STT details

NVIDIA Nemotron 0.6B is a cache-aware streaming speech-to-text model. It
produces cased, punctuated transcripts with very low latency.

- **GPU path**: Docker container built from `selfhost/stt/`. ~1.6 GB VRAM (bf16).
  Partial lag ~43 ms, final after flush ~95 ms. WER 2.2%.
- **Mac path**: Python server using MLX. ~1.24 GB MLX memory.
  Partial lag ~44-55 ms, final ~100-149 ms. Same WER.
- **API**: WebSocket at `/v1/stream` (raw PCM16 in, JSON partials/finals out),
  plus OpenAI-compatible `POST /v1/audio/transcriptions` for file uploads.
- **Config**: `STT_RIGHT_CONTEXT` (latency/accuracy tradeoff), `STT_DTYPE`, `STT_PORT`.

### 5. iOS app (optional)

Requires a Mac with Xcode. Free Apple developer signing (re-sign every 7 days).

```sh
# From your Linux server (or wherever you cloned the repo):
selfhost/ios/build-on-mac.sh --sync-only    # rsync code to the Mac
# Then on the Mac:
cd ~/happy-build
selfhost/ios/build-on-mac.sh --build-only   # expo prebuild + xcodebuild
selfhost/ios/build-on-mac.sh --install-only # install on connected iPhone
```

See `selfhost/ios/README.md` and `selfhost/ios/BUILD-ON-MAC.md` for details,
including free-team limitations and troubleshooting.

## Environment files

| File | Purpose | Template |
|---|---|---|
| `selfhost/.env` | Server secrets, Postgres, public URL, LiveKit keys | `.env.example` |
| `selfhost/.env.voice` | Voice pipeline config: GPU indices, models, LLM endpoint | `.env.voice.example` |
| `selfhost/ios/.env.ios` | iOS signing: Apple team ID (lives on the Mac, never synced) | `.env.ios.example` |

## Directory structure

```
selfhost/
├── README.md              ← you are here
├── docker-compose.yml     ← happy-server + Postgres
├── compose.voice.yml      ← voice pipeline (LiveKit, STT, TTS, agent)
├── Makefile               ← make up/down/status/logs + includes below
├── voice.mk               ← make voice-up/voice-status/voice-smoke/...
├── cli.mk                 ← make cli-install/cli-status/...
├── webapp.mk              ← make webapp-build
├── VOICE_SERVICES.md      ← full voice contract (endpoints, protocols, latencies)
├── livekit.yaml            ← LiveKit server config
├── .env.example
├── .env.voice.example
├── scripts/               ← build-webapp.sh, voice-smoke.sh, voice-stream-e2e.mjs
├── stt/                   ← Nemotron STT Docker build context
├── mac-voice/             ← Kokoro TTS + Nemotron STT for Apple Silicon
│   ├── README.md          ← setup, benchmarks, tuning
│   ├── run.sh             ← setup/start/stop/status
│   ├── install-service.sh ← launchd + pf firewall
│   ├── tts_server.py
│   ├── stt_server.py
│   └── requirements.txt
├── ios/                   ← iOS build scripts
│   ├── README.md
│   ├── BUILD-ON-MAC.md
│   └── build-on-mac.sh
└── voice-test/            ← browser test page (make voice-try)
```

## Multiple machines

Happy supports multiple machines. Each computer running `happy-cli` registers as
a "machine" in the app. When starting a new session, you pick which machine to
use. To add a machine:

1. Install `happy-cli` on the new machine
2. Point it at your happy-server URL
3. Register/authenticate it
4. It appears in the app's machine picker

For voice services on a separate Mac, see Option B above — the Mac runs STT/TTS
and the voice agent on your main server connects to it over the LAN.
