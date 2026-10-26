"""Local streaming STT for Apple Silicon (MLX), API-compatible with selfhost/stt/server.py.

Endpoints (same shapes as the GPU server, see selfhost/VOICE_SERVICES.md):
  GET  /health                     -> {"status":"ok", ...}
  WS   /v1/stream                  -> binary PCM16LE mono 16 kHz in, JSON partial/final out
  POST /v1/audio/transcriptions    -> OpenAI-style file transcription (multipart "file")

Backends (STT_BACKEND):
  nemotron (default)  nvidia/nemotron-speech-streaming-en-0.6b through mlx-audio's native MLX port of
                      the cache-aware FastConformer RNNT: the same model and streaming scheme as the server.
  parakeet            parakeet-mlx (Parakeet TDT 0.6B) with its local-attention streaming API.

Every MLX call runs on one dedicated thread, so streams are serialized exactly like the
server's single GPU lock.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

import mlx.core as mx
import numpy as np
import soundfile as sf
from fastapi import FastAPI, File, Form, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, PlainTextResponse

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("stt")

BACKEND = os.environ.get("STT_BACKEND", "nemotron").lower()
NEMOTRON_MODEL = os.environ.get("STT_MODEL", "nvidia/nemotron-speech-streaming-en-0.6b")
PARAKEET_MODEL = os.environ.get("STT_PARAKEET_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")
# Nemotron right context in 80 ms encoder frames: 0 -> 80 ms chunks, 1 -> 160 ms (server default), 6 -> 560 ms, 13 -> 1120 ms
RIGHT_CONTEXT = int(os.environ.get("STT_RIGHT_CONTEXT", "1"))
FILE_RIGHT_CONTEXT = int(os.environ.get("STT_FILE_RIGHT_CONTEXT", "13"))
# Encoder precision. fp16 is ~30% faster than fp32 on M1 with identical transcripts on the bench clips.
STT_DTYPE = os.environ.get("STT_DTYPE", "fp16").lower()
# Parakeet local-attention context (left, right) in 80 ms encoder frames, and the feed chunk size.
PARAKEET_CONTEXT = tuple(int(x) for x in os.environ.get("STT_PARAKEET_CONTEXT", "128,16").split(","))
PARAKEET_CHUNK_MS = int(os.environ.get("STT_PARAKEET_CHUNK_MS", "160"))
DEFAULT_ENDPOINT_MS = int(os.environ.get("STT_ENDPOINT_MS", "0"))
WARMUP = os.environ.get("WARMUP", "1") != "0"
SAMPLE_RATE = 16000

app = FastAPI(title="mac-mlx-streaming-stt")
MLX = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")


async def on_mlx(fn, *args):
    return await asyncio.get_running_loop().run_in_executor(MLX, fn, *args)


@dataclass
class StreamState:
    impl: object
    tokens: list = field(default_factory=list)
    pending: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float32))
    text: str = ""
    audio_samples: int = 0


class NemotronEngine:
    """mlx-audio's NemotronStreamingSession: per-layer attention/conv caches, O(n), no recompute."""

    DELAYS = {0: 80, 1: 160, 6: 560, 13: 1120}

    def __init__(self) -> None:
        from mlx_audio.stt import load

        t0 = time.time()
        self.model_name = NEMOTRON_MODEL
        self.model = load(NEMOTRON_MODEL)
        if RIGHT_CONTEXT not in self.DELAYS:
            raise ValueError(f"STT_RIGHT_CONTEXT must be one of {sorted(self.DELAYS)}")
        self.delay_ms = self.DELAYS[RIGHT_CONTEXT]
        self.cast = {"fp16": mx.float16, "bf16": mx.bfloat16, "fp32": None}[STT_DTYPE]
        if self.cast is not None:
            # Encoder weights only; the mel frontend output is cast to match (see new_state), the
            # RNNT prediction net and joint stay fp32.
            self.model.encoder.set_dtype(self.cast)
        self.att_context_size = [self.model.default_att_context_size[0], RIGHT_CONTEXT]
        sub = self.model.encoder_config.subsampling_factor
        hop = self.model.preprocessor_config.hop_length
        self.chunk_samples = (RIGHT_CONTEXT + 1) * sub * hop
        self.chunk_ms = self.chunk_samples * 1000 // SAMPLE_RATE
        self.load_s = time.time() - t0

    def info(self) -> dict:
        return {"model": self.model_name, "chunk_ms": self.chunk_ms, "att_context_size": self.att_context_size, "dtype": STT_DTYPE}

    def new_state(self, right_context: int | None = None) -> StreamState:
        delay = self.delay_ms if right_context is None else self.DELAYS[right_context]
        s = self.model.create_streaming_session(transcription_delay_ms=delay)
        if self.cast is not None:
            push = s._frontend.push
            s._frontend.push = lambda x, final=False: push(x, final=final).astype(self.cast)
        return StreamState(impl=s)

    def step(self, st: StreamState, chunk: np.ndarray) -> str:
        s = st.impl
        s.feed(chunk)
        while True:
            st.tokens += s.step(max_decode_tokens=1024)
            if not s._encoded and s._queued == 0:
                break
        return "".join(st.tokens).strip()

    def finish(self, st: StreamState, tail: np.ndarray) -> str:
        s = st.impl
        if tail.size:
            s.feed(tail)
        s.close()
        while not s.done:
            st.tokens += s.step(max_decode_tokens=1024)
        mx.clear_cache()
        return "".join(st.tokens).strip()

    def transcribe_file(self, audio: np.ndarray) -> str:
        # Whole files use the 1120 ms look-ahead (STT_FILE_RIGHT_CONTEXT=13): 7x fewer encoder steps
        # than 160 ms chunks, and the model's most accurate setting.
        st = self.new_state(FILE_RIGHT_CONTEXT)
        return self.finish(st, audio.astype(np.float32))


class ParakeetEngine:
    """parakeet-mlx StreamingParakeet: local attention, re-encodes the right-context window each chunk."""

    def __init__(self) -> None:
        from parakeet_mlx import from_pretrained

        t0 = time.time()
        self.model_name = PARAKEET_MODEL
        self.model = from_pretrained(PARAKEET_MODEL)  # bf16
        self.model.encoder.set_attention_model("rel_pos_local_attn", PARAKEET_CONTEXT)
        self.chunk_samples = PARAKEET_CHUNK_MS * SAMPLE_RATE // 1000
        self.chunk_ms = PARAKEET_CHUNK_MS
        self.load_s = time.time() - t0

    def info(self) -> dict:
        return {"model": self.model_name, "chunk_ms": self.chunk_ms, "context_size": list(PARAKEET_CONTEXT), "dtype": "bf16"}

    def new_state(self) -> StreamState:
        from parakeet_mlx.parakeet import StreamingParakeet

        # Constructed without __enter__: the local attention model is set once for the whole process.
        return StreamState(impl=StreamingParakeet(self.model, PARAKEET_CONTEXT, 1, keep_original_attention=True))

    def step(self, st: StreamState, chunk: np.ndarray) -> str:
        st.impl.add_audio(mx.array(chunk, dtype=mx.bfloat16))
        return st.impl.result.text.strip()

    def finish(self, st: StreamState, tail: np.ndarray) -> str:
        # Right-context worth of silence so the draft region is decoded with real look-ahead.
        pad = np.zeros(PARAKEET_CONTEXT[1] * 1280 + 2 * self.chunk_samples, dtype=np.float32)
        st.impl.add_audio(mx.array(np.concatenate([tail, pad]), dtype=mx.bfloat16))
        text = st.impl.result.text.strip()
        mx.clear_cache()
        return text

    def transcribe_file(self, audio: np.ndarray) -> str:
        from parakeet_mlx.audio import get_logmel

        self.model.encoder.set_attention_model("rel_pos")
        try:
            mel = get_logmel(mx.array(audio, dtype=mx.bfloat16), self.model.preprocessor_config)
            return self.model.generate(mel)[0].text.strip()
        finally:
            self.model.encoder.set_attention_model("rel_pos_local_attn", PARAKEET_CONTEXT)
            mx.clear_cache()


ENGINE: NemotronEngine | ParakeetEngine | None = None
STARTED = time.time()


def _load():
    eng = {"nemotron": NemotronEngine, "parakeet": ParakeetEngine}[BACKEND]()
    if WARMUP:
        st = eng.new_state()
        for _ in range(4):
            eng.step(st, np.zeros(eng.chunk_samples, dtype=np.float32))
        eng.finish(st, np.zeros(0, dtype=np.float32))
        eng.transcribe_file(np.zeros(SAMPLE_RATE, dtype=np.float32))
    return eng


@app.on_event("startup")
async def _startup() -> None:
    global ENGINE
    ENGINE = await on_mlx(_load)
    log.info("loaded %s (%s) in %.1fs, ready %.1fs after start; warmup=%s", ENGINE.model_name, BACKEND, ENGINE.load_s, time.time() - STARTED, WARMUP)


def _mem() -> dict:
    import psutil

    return {
        "rss_mb": round(psutil.Process().memory_info().rss / 2**20),
        "mlx_active_mb": round(mx.get_active_memory() / 2**20),
        "mlx_peak_mb": round(mx.get_peak_memory() / 2**20),
        "mlx_cache_mb": round(mx.get_cache_memory() / 2**20),
    }


@app.get("/health")
async def health():
    if ENGINE is None:
        return JSONResponse({"status": "loading"}, status_code=503)
    return {"status": "ok", "backend": BACKEND, "sample_rate": SAMPLE_RATE, "device": "mlx-metal", **ENGINE.info(),
            "load_s": round(ENGINE.load_s, 1), "memory": _mem()}


async def _feed(st: StreamState, pcm: np.ndarray) -> list[str]:
    assert ENGINE is not None
    st.pending = np.concatenate([st.pending, pcm]) if st.pending.size else pcm
    outs = []
    n = ENGINE.chunk_samples
    while st.pending.size >= n:
        chunk, st.pending = st.pending[:n], st.pending[n:]
        st.audio_samples += n
        outs.append(await on_mlx(ENGINE.step, st, chunk))
    return outs


@app.websocket("/v1/stream")
async def stream(ws: WebSocket):
    await ws.accept()
    assert ENGINE is not None
    q = ws.query_params
    sr = int(q.get("sample_rate", SAMPLE_RATE))
    if sr != SAMPLE_RATE:
        await ws.send_json({"type": "error", "message": f"sample_rate must be {SAMPLE_RATE}"})
        await ws.close(code=1003)
        return
    endpoint_ms = int(q.get("endpoint_ms", DEFAULT_ENDPOINT_MS))
    interim = q.get("interim_results", "true").lower() != "false"

    st = await on_mlx(ENGINE.new_state)
    segment = 0
    last_change_samples = 0
    await ws.send_json({"type": "ready", "model": ENGINE.model_name, "sample_rate": SAMPLE_RATE, "chunk_ms": ENGINE.chunk_ms})

    async def emit_final() -> None:
        nonlocal st, segment, last_change_samples
        t0 = time.monotonic()
        tail, st.pending = st.pending, np.zeros(0, dtype=np.float32)
        st.audio_samples += tail.size
        text = await on_mlx(ENGINE.finish, st, tail)
        await ws.send_json({
            "type": "final",
            "segment_id": segment,
            "text": text,
            "audio_ms": st.audio_samples * 1000 // SAMPLE_RATE,
            "flush_ms": round((time.monotonic() - t0) * 1000, 1),
        })
        segment += 1
        st = await on_mlx(ENGINE.new_state)
        last_change_samples = 0

    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break
            if msg.get("bytes") is not None:
                data = msg["bytes"]
                if len(data) % 2:
                    data = data[:-1]
                pcm = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
                for text in await _feed(st, pcm):
                    if text != st.text:
                        st.text = text
                        last_change_samples = st.audio_samples
                        if interim:
                            await ws.send_json({"type": "partial", "segment_id": segment, "text": text,
                                                "audio_ms": st.audio_samples * 1000 // SAMPLE_RATE})
                if endpoint_ms > 0 and st.text and (st.audio_samples - last_change_samples) * 1000 // SAMPLE_RATE >= endpoint_ms:
                    await emit_final()
            elif msg.get("text") is not None:
                try:
                    ctrl = json.loads(msg["text"])
                except json.JSONDecodeError:
                    await ws.send_json({"type": "error", "message": "invalid json control message"})
                    continue
                kind = ctrl.get("type")
                if kind == "flush":
                    await emit_final()
                elif kind == "reset":
                    st = await on_mlx(ENGINE.new_state)
                    segment += 1
                elif kind in ("close", "eof"):
                    if st.audio_samples or st.pending.size:
                        await emit_final()
                    await ws.send_json({"type": "closed"})
                    await ws.close()
                    return
                else:
                    await ws.send_json({"type": "error", "message": f"unknown control type {kind!r}"})
    except WebSocketDisconnect:
        pass
    except Exception as e:  # noqa: BLE001
        log.exception("stream error")
        try:
            await ws.send_json({"type": "error", "message": str(e)})
            await ws.close(code=1011)
        except Exception:  # noqa: BLE001
            pass


@app.post("/v1/audio/transcriptions")
async def transcribe(file: UploadFile = File(...), model: str = Form(default=""), response_format: str = Form(default="json")):
    assert ENGINE is not None
    raw = await file.read()
    audio, sr = sf.read(io.BytesIO(raw), dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        from math import gcd

        from scipy.signal import resample_poly

        g = gcd(sr, SAMPLE_RATE)
        audio = resample_poly(audio, SAMPLE_RATE // g, sr // g).astype(np.float32)
    t0 = time.monotonic()
    text = await on_mlx(ENGINE.transcribe_file, audio)
    elapsed = time.monotonic() - t0
    if response_format == "text":
        return PlainTextResponse(text)
    return {"text": text, "duration": round(audio.size / SAMPLE_RATE, 3), "processing_s": round(elapsed, 3)}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=os.environ.get("VOICE_HOST", "127.0.0.1"), port=int(os.environ.get("STT_PORT", "8090")), ws_max_size=16 * 2**20)
