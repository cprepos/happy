"""Local Kokoro-82M TTS for Apple Silicon (mlx-audio), API-compatible with Kokoro-FastAPI.

Endpoints:
  POST /v1/audio/speech   {"model":"kokoro","input":"...","voice":"af_heart","response_format":"pcm","stream":true,"speed":1.0}
                          pcm -> raw PCM16 LE mono 24 kHz, streamed (chunked) as each text chunk is synthesized.
                          wav/flac/mp3/opus -> whole file (wav also streams, with an open-ended header).
  GET  /v1/audio/voices   {"voices":[{"id":"af_heart","name":"af_heart"}, ...]}
  GET  /health

Latency: on an M1 the Kokoro vocoder costs ~90 ms per second of audio plus ~100 ms per call, so
time to first audio grows with the length of the first synthesized chunk. Text is split into
sentences and the first sentence is split once more, at the first clause boundary (comma,
semicolon, colon, dash) or else before a conjunction ("so", "and", "because", ...), or else after
TTS_FIRST_MAX_WORDS words, keeping at least TTS_FIRST_MIN_WORDS words in the first piece. The rest
is synthesized while the first piece plays (RTF ~0.12). TTS_FAST_FIRST=0 turns the split off.

mp3 streams too: a LAME encoder (lameenc) runs across the whole response, so frames go out as
soon as each piece is synthesized.
"""

from __future__ import annotations

import asyncio
import io
import logging
import os
import re
import struct
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import mlx.core as mx
import numpy as np
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("tts")

MODEL_ID = os.environ.get("TTS_MODEL", "prince-canuma/Kokoro-82M")
DEFAULT_VOICE = os.environ.get("TTS_VOICE", "af_heart")
FAST_FIRST = os.environ.get("TTS_FAST_FIRST", "1") != "0"
FIRST_MIN_WORDS = int(os.environ.get("TTS_FIRST_MIN_WORDS", "3"))
FIRST_MAX_WORDS = int(os.environ.get("TTS_FIRST_MAX_WORDS", "8"))
MP3_KBPS = int(os.environ.get("TTS_MP3_KBPS", "96"))
WARMUP = os.environ.get("WARMUP", "1") != "0"
SAMPLE_RATE = 24000

app = FastAPI(title="mac-mlx-kokoro-tts")
MLX = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
MODEL = None
VOICES: list[str] = []
LOAD_S = 0.0
STARTED = time.time()

_SENT = re.compile(r"(?<=[.!?])\s+|\n+")
_CLAUSE = re.compile(r"(?<=[,;:])\s+|\s+[-–—]+\s+")


_CONJ = {"so", "and", "but", "or", "because", "before", "after", "when", "while", "then", "which", "that", "if",
         "until", "unless", "since", "where", "although", "though", "once"}


def _split_first(sentence: str) -> list[str]:
    w = sentence.split()
    if len(w) <= FIRST_MAX_WORDS:
        return [sentence]
    for m in _CLAUSE.finditer(sentence):
        n = len(sentence[: m.start()].split())
        if FIRST_MIN_WORDS <= n <= 2 * FIRST_MAX_WORDS and sentence[m.end():].strip():
            return [sentence[: m.start()].strip(), sentence[m.end():].strip()]
    for i in range(FIRST_MIN_WORDS, min(len(w) - 2, 2 * FIRST_MAX_WORDS)):
        if w[i].lower().strip(",;:") in _CONJ:
            return [" ".join(w[:i]), " ".join(w[i:])]
    return [" ".join(w[:FIRST_MAX_WORDS]), " ".join(w[FIRST_MAX_WORDS:])]


def split_text(text: str) -> list[str]:
    parts = [p.strip() for p in _SENT.split(text.strip()) if p and p.strip()]
    if FAST_FIRST and parts:
        parts = _split_first(parts[0]) + parts[1:]
    return parts


def _lang(voice: str) -> str:
    return voice.split("+")[0].split(",")[0][:1] or "a"


def _load():
    global MODEL, VOICES, LOAD_S
    from huggingface_hub import snapshot_download
    from mlx_audio.tts.utils import load_model

    t0 = time.time()
    MODEL = load_model(MODEL_ID)
    VOICES = sorted(p.stem for p in (Path(snapshot_download(MODEL_ID)) / "voices").glob("*.safetensors"))
    if WARMUP:
        for _ in _synth("Hello there. This warms up the model, the phonemizer and the pipeline.", DEFAULT_VOICE, 1.0, threading.Event()):
            pass
    LOAD_S = time.time() - t0


def _synth(text: str, voice: str, speed: float, cancel: threading.Event):
    """Runs on the MLX thread. Yields float32 numpy chunks at 24 kHz."""
    v = voice.replace("+", ",")
    for part in split_text(text):
        if cancel.is_set():
            return
        for r in MODEL.generate(text=part, voice=v, speed=speed, lang_code=_lang(voice), split_pattern=None):
            yield np.asarray(r.audio, dtype=np.float32).reshape(-1)
            if cancel.is_set():
                return
    mx.clear_cache()


def _pcm16(x: np.ndarray) -> bytes:
    return (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()


def _wav_header(nbytes: int = 0xFFFFFFFF - 36) -> bytes:
    return b"RIFF" + struct.pack("<I", min(nbytes + 36, 0xFFFFFFFF)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16) + b"data" + struct.pack("<I", min(nbytes, 0xFFFFFFFF))


@app.on_event("startup")
async def _startup() -> None:
    await asyncio.get_running_loop().run_in_executor(MLX, _load)
    log.info("loaded %s in %.1fs (ready %.1fs after start), %d voices, warmup=%s", MODEL_ID, LOAD_S, time.time() - STARTED, len(VOICES), WARMUP)


@app.get("/health")
async def health():
    if MODEL is None:
        return JSONResponse({"status": "loading"}, status_code=503)
    import psutil

    return {"status": "ok", "model": MODEL_ID, "sample_rate": SAMPLE_RATE, "device": "mlx-metal", "load_s": round(LOAD_S, 1),
            "memory": {"rss_mb": round(psutil.Process().memory_info().rss / 2**20),
                       "mlx_active_mb": round(mx.get_active_memory() / 2**20),
                       "mlx_peak_mb": round(mx.get_peak_memory() / 2**20),
                       "mlx_cache_mb": round(mx.get_cache_memory() / 2**20)}}


@app.get("/v1/audio/voices")
async def voices():
    return {"voices": [{"id": v, "name": v} for v in VOICES]}


@app.get("/v1/models")
async def models():
    return {"object": "list", "data": [{"id": "kokoro", "object": "model", "owned_by": "local"}]}


@app.post("/v1/audio/speech")
async def speech(request: Request):
    if MODEL is None:
        return JSONResponse({"error": "loading"}, status_code=503)
    body = await request.json()
    text = (body.get("input") or "").strip()
    if not text:
        return JSONResponse({"error": "input is empty"}, status_code=400)
    voice = body.get("voice") or DEFAULT_VOICE
    unknown = [v for v in re.split(r"[+,]", voice) if v not in VOICES]
    if unknown:
        return JSONResponse({"error": f"unknown voice(s): {unknown}"}, status_code=400)
    speed = float(body.get("speed", 1.0))
    fmt = (body.get("response_format") or "mp3").lower()
    stream = bool(body.get("stream", True))
    if fmt not in ("pcm", "wav", "flac", "mp3", "opus"):
        return JSONResponse({"error": f"unsupported response_format {fmt!r}"}, status_code=400)

    loop = asyncio.get_running_loop()
    q: asyncio.Queue = asyncio.Queue()
    cancel = threading.Event()
    _END = object()

    def worker():
        try:
            for chunk in _synth(text, voice, speed, cancel):
                loop.call_soon_threadsafe(q.put_nowait, chunk)
        except Exception as e:  # noqa: BLE001
            log.exception("synthesis failed")
            loop.call_soon_threadsafe(q.put_nowait, e)
        finally:
            loop.call_soon_threadsafe(q.put_nowait, _END)

    loop.run_in_executor(MLX, worker)

    async def chunks():
        try:
            while True:
                item = await q.get()
                if item is _END:
                    return
                if isinstance(item, Exception):
                    raise item
                yield item
        finally:
            cancel.set()

    if stream and fmt in ("pcm", "wav", "mp3"):
        async def body_iter():
            enc = None
            if fmt == "wav":
                yield _wav_header()
            if fmt == "mp3":
                import lameenc

                enc = lameenc.Encoder()
                enc.set_bit_rate(MP3_KBPS)
                enc.set_in_sample_rate(SAMPLE_RATE)
                enc.set_channels(1)
                enc.set_quality(5)
            async for c in chunks():
                if enc is None:
                    yield _pcm16(c)
                else:
                    b = enc.encode(_pcm16(c))
                    if b:
                        yield bytes(b)
            if enc is not None:
                tail = enc.flush()
                if tail:
                    yield bytes(tail)

        media = {"pcm": "audio/pcm", "wav": "audio/wav", "mp3": "audio/mpeg"}[fmt]
        return StreamingResponse(body_iter(), media_type=media, headers={"X-Sample-Rate": str(SAMPLE_RATE)})

    audio = np.concatenate([c async for c in chunks()] or [np.zeros(0, dtype=np.float32)])
    if fmt == "pcm":
        return Response(_pcm16(audio), media_type="audio/pcm")
    if fmt == "wav":
        data = _pcm16(audio)
        return Response(_wav_header(len(data)) + data, media_type="audio/wav")
    import soundfile as sf

    buf = io.BytesIO()
    sf_fmt = {"flac": ("FLAC", None), "mp3": ("MP3", None), "opus": ("OGG", "OPUS")}[fmt]
    sf.write(buf, audio, SAMPLE_RATE, format=sf_fmt[0], subtype=sf_fmt[1])
    media = {"flac": "audio/flac", "mp3": "audio/mpeg", "opus": "audio/ogg"}[fmt]
    return Response(buf.getvalue(), media_type=media)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=os.environ.get("VOICE_HOST", "127.0.0.1"), port=int(os.environ.get("TTS_PORT", "8880")))
