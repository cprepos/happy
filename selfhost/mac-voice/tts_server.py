"""Local Kokoro-82M TTS for Apple Silicon (mlx-audio), API-compatible with Kokoro-FastAPI.

Endpoints:
  POST /v1/audio/speech   {"model":"kokoro","input":"...","voice":"af_heart","response_format":"pcm","stream":true,"speed":1.0}
                          pcm -> raw PCM16 LE mono 24 kHz, streamed (chunked) as each text chunk is synthesized.
                          wav/flac/mp3/opus -> whole file (wav also streams, with an open-ended header).
  GET  /v1/audio/voices   {"voices":[{"id":"af_heart","name":"af_heart"}, ...]}
  GET  /health

Latency: on an M1 the Kokoro vocoder costs ~90 ms per second of audio plus ~100 ms per call, so
time to first audio grows with the length of the first synthesized chunk. So the first sentence is
split once, at the first clause boundary (comma, semicolon, colon, dash) or else before a
conjunction ("so", "and", "because", ...), keeping at least TTS_FIRST_MIN_WORDS words, and the rest
is synthesized while that piece plays (RTF ~0.145). TTS_FAST_FIRST=0 turns the split off.

A sentence with neither a clause boundary nor a conjunction in the window is left whole. Cutting
it after TTS_FIRST_MAX_WORDS words instead lands mid-phrase -- "the source folder for you | just
now" -- which inserted 0.24 s of silence there and restarted the intonation, and it bought about
30 ms: the first audible word measured 713 ms at a cap of 8 against 743 ms with no split at all.
TTS_FIRST_HARD_CUT=1 restores it, which is worth ~190 ms at a cap of 4. TTS_FIRST_MAX_WORDS still
bounds the clause and conjunction search either way.

Everything after that opening piece is grouped into TTS_CHUNK_WORDS-word pieces rather than one
piece per sentence, because sentence boundaries inside a piece are Kokoro's own and need no
joining. Synthesizing the whole remainder in one piece would be smoother still but underruns: on
a seven-sentence reply the remainder is 17.58 s of audio needing 2.87 s against the 1.45 s of
playback the opening piece buys.

Every generate() call pads its audio, so each piece is trimmed before it goes out -- see _trim.
The tail keeps a pause sized by the punctuation the piece ends on (_pause_after), because one
value for every boundary clipped sentence breaks shorter than Kokoro's own 0.28-0.62 s.
Without that, a split inserts the next piece's lead in the middle of the sentence: "I have sent
that along." measured 2.35 s whole against 3.52 s in two pieces, with a 0.84 s hole at the join,
and that hole is what a listener hears as a stop between sentences. Trimming removes it and the
lead in front of the reply with it, so speech now starts 60 ms into the audio rather than 940 ms.
TTS_TRIM_PIECES=0 turns it off.

Each piece is synthesized independently and its intonation contour restarts, so where a piece ends
is a prosody choice and not only a latency one. Time to the first audible word on the nine-word
sentence above: cap 4 gives 550 ms, cap 6 667 ms, cap 8 713 ms, cap 12 722 ms, and
TTS_FAST_FIRST=0 743 ms -- but on a 22-word sentence turning the split off costs 1543 ms against
681 ms, which is what the split is for.

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
TRIM_PIECES = os.environ.get("TTS_TRIM_PIECES", "1") != "0"
ONSET_RMS = int(os.environ.get("TTS_ONSET_RMS", "1012")) / 32768.0
VALLEY_RMS = int(os.environ.get("TTS_VALLEY_RMS", "260")) / 32768.0
MIN_LEAD = float(os.environ.get("TTS_MIN_LEAD", "0.12"))
MAX_TRIM = float(os.environ.get("TTS_MAX_TRIM", "1.5"))
KEEP_PAD = 0.030
# How much silence a piece keeps at its end, by what it ends with. Kokoro's own pacing for the
# same text, measured in one generate() call, is 0.28-0.72 s between sentences and 0.54-0.72 s at
# a comma, so a single 0.20 s value clipped every boundary short. TTS_PAUSE still overrides all
# three at once, for an install that already sets it.
_PAUSE_ALL = os.environ.get("TTS_PAUSE")
PAUSE_SENTENCE = float(os.environ.get("TTS_PAUSE_SENTENCE", _PAUSE_ALL or "0.40"))
PAUSE_CLAUSE = float(os.environ.get("TTS_PAUSE_CLAUSE", _PAUSE_ALL or "0.45"))
PAUSE_PHRASE = float(os.environ.get("TTS_PAUSE_PHRASE", _PAUSE_ALL or "0.05"))
# Words per piece once the opening piece has been split off. Sentences inside one piece are
# Kokoro's to pace, which is what makes them smooth; 25 words is about 8 s of audio, ~1.2 s to
# synthesize at RTF 0.145, against the >=1.4 s of audio the piece before it buys.
CHUNK_WORDS = int(os.environ.get("TTS_CHUNK_WORDS", "25"))
# Cut the opening piece after FIRST_MAX_WORDS even with no clause or conjunction there. Off: it
# lands mid-phrase, which inserts a pause and restarts the intonation for ~30 ms of latency.
FIRST_HARD_CUT = os.environ.get("TTS_FIRST_HARD_CUT", "0") != "0"
FADE = 0.005
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
    if FIRST_HARD_CUT:
        return [" ".join(w[:FIRST_MAX_WORDS]), " ".join(w[FIRST_MAX_WORDS:])]
    return [sentence]  # nowhere to split that a listener would not hear


def _group(sentences: list[str]) -> list[str]:
    """Merge sentences up to CHUNK_WORDS, so Kokoro paces the boundaries inside a piece."""
    out: list[str] = []
    for s in sentences:
        if out and len(out[-1].split()) + len(s.split()) <= CHUNK_WORDS:
            out[-1] = f"{out[-1]} {s}"
        else:
            out.append(s)
    return out


def split_text(text: str) -> list[str]:
    parts = [p.strip() for p in _SENT.split(text.strip()) if p and p.strip()]
    if FAST_FIRST and parts:
        head = _split_first(parts[0])
        # Only the opening piece is sized for latency; group the rest.
        return head[:1] + _group(head[1:] + parts[1:])
    return _group(parts)


def _lang(voice: str) -> str:
    return voice.split("+")[0].split(",")[0][:1] or "a"


def _load():
    global MODEL, VOICES, LOAD_S
    from huggingface_hub import snapshot_download
    from mlx_audio.tts.models.kokoro import pipeline as _kp
    from mlx_audio.tts.models.kokoro.voice import load_voice_tensor
    from mlx_audio.tts.utils import load_model

    t0 = time.time()
    model_dir = Path(MODEL_ID)
    if model_dir.is_dir():
        # local model dir (e.g. a fine-tuned Kokoro); voices live in <dir>/voices
        MODEL = load_model(str(model_dir))
        voice_dir = model_dir / "voices"
    else:
        MODEL = load_model(MODEL_ID)
        voice_dir = Path(snapshot_download(MODEL_ID)) / "voices"
    VOICES = sorted(p.stem for p in voice_dir.glob("*.safetensors"))

    # Resolve voices from the local dir first, so custom voices that do not
    # exist on the hub work without HF resolution (and generate()'s per-call
    # voice-cache reset stays cheap: one file read, no network).
    _orig_load_voice = _kp.KokoroPipeline.load_single_voice

    def _load_voice(self, voice: str):
        if voice not in self.voices and not voice.endswith(".safetensors"):
            p = voice_dir / f"{voice}.safetensors"
            if p.exists():
                self.voices[voice] = load_voice_tensor(str(p))
                return self.voices[voice]
        return _orig_load_voice(self, voice)

    _kp.KokoroPipeline.load_single_voice = _load_voice
    if WARMUP:
        for _ in _synth("Hello there. This warms up the model, the phonemizer and the pipeline.", DEFAULT_VOICE, 1.0, threading.Event()):
            pass
    LOAD_S = time.time() - t0


def _trim(x: np.ndarray, pause: float = PAUSE_SENTENCE) -> np.ndarray:
    """Drop the speech-free lead and the over-long tail Kokoro puts around a piece.

    Every generate() call pads its audio: measured on an M1, "I have sent that" holds speech
    from 0.36 s to 1.00 s of a 1.38 s buffer, and "that along." from 0.46 s to 0.76 s of
    another 1.38 s. Synthesize a sentence as two pieces and those two pads meet in the middle
    of it -- 0.38 s of tail against 0.46 s of lead, the 0.84 s hole measured at the join. A
    client can trim the lead off the start of a response but not one that arrives mid-stream,
    so it is trimmed here, where every piece is still a whole array.

    The levels come from the agent's `happy_voice/tts_trim.py`, which derived them by sweep:
    speech is two consecutive 10 ms windows at ONSET_RMS, and the cut goes to the end of the
    quiet stretch in front of that, found by search, not to the threshold. Both ways of being
    wrong keep audio: no onset found passes the piece through, and an onset found inside the
    lead puts the valley search at the start, where it trims nothing. MIN_LEAD is lower than
    the agent's 0.4 s because this only ever looks in front of a piece's first speech, so a
    quiet run there cannot be a pause inside the speech.

    The tail is set to `pause` rather than removed, because that silence is the spacing to
    whatever comes next -- see _pause_after for how much each piece asks for. Set, not cut:
    Kokoro's pad is 0.22-0.38 s depending on the text, so a sentence boundary that wants 0.40 s
    has to be padded out, and silence between pieces exists only if it is put here, the next
    piece having had its own lead trimmed off.
    """
    win = SAMPLE_RATE // 100  # 10 ms
    n = len(x) // win
    if n < 3:
        return x
    w = x[: n * win].reshape(n, win).astype(np.float64)
    rms = np.sqrt((w * w).mean(axis=1))
    def runs(mask: np.ndarray, k: int) -> np.ndarray:
        """Where a run of `k` consecutive true windows starts."""
        if len(mask) < k:
            return np.zeros(0, dtype=bool)
        out = mask[: len(mask) - k + 1].copy()
        for i in range(1, k):
            out &= mask[i : len(mask) - k + 1 + i]
        return out

    # 50 ms of speech, not 20: the lead itself can hold a 30 ms click at speech level (seen on
    # "that along."), and treating that as the onset leaves the whole lead in place. Real
    # speech runs measure 140-260 ms, so the longer run costs nothing.
    pair = runs(rms >= ONSET_RMS, 5)
    if not pair.any():
        return x  # nothing we can positively call speech: keep it whole
    first, last = int(pair.argmax()), int(len(pair) - 1 - pair[::-1].argmax())

    start = 0
    qpair = runs(rms <= VALLEY_RMS, 2)
    lead = [i for i in range(first) if qpair[i]]
    if lead:
        cut = lead[-1] * win
        if MIN_LEAD * SAMPLE_RATE <= cut <= MAX_TRIM * SAMPLE_RATE:
            start = max(0, cut - int(KEEP_PAD * SAMPLE_RATE))

    end = len(x)
    pad_after = 0
    # Where speech really stops: `last` is only where the final 50 ms run starts, and a word's
    # decay keeps crossing ONSET after it. Searching from just past the run found quiet windows
    # inside the last word and measured the pause from a point speech had not left, delivering
    # 0.22 s where 0.40 s was asked for.
    loud = np.where(rms >= ONSET_RMS)[0]
    quiet_from = max(last + 5, int(loud[-1]) + 1) if len(loud) else last + 5
    tail = [i for i in range(quiet_from, len(qpair)) if qpair[i]]
    if tail:
        keep = tail[0] * win + int(pause * SAMPLE_RATE)
        if keep < end:
            end = keep
        else:
            pad_after = keep - end  # the pad is shorter than the spacing: add the difference
    else:
        # No quiet run to be found: the pad is noisy, or there is none. Never cut on a guess, but
        # silence can still be added after the last speech run, where it cannot clip anything.
        keep = min(len(x), (last + 5) * win) + int(pause * SAMPLE_RATE)
        if keep > end:
            pad_after = keep - end

    if start == 0 and end == len(x) and not pad_after:
        return x
    y = x[start:end].copy()
    fade = min(int(FADE * SAMPLE_RATE), len(y))
    if start and fade:
        y[:fade] *= np.linspace(0.0, 1.0, fade, dtype=np.float32)
    if end < len(x) and fade:
        y[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
    if pad_after:
        # No fade: nothing was cut here, the piece just ends quieter than the spacing needs.
        y = np.concatenate([y, np.zeros(pad_after, dtype=y.dtype)])
    return y


def _pause_after(part: str) -> float:
    """Silence to keep after a piece, from the punctuation it ends on."""
    end = part.rstrip()[-1:]
    if end in ".!?\u2026":
        return PAUSE_SENTENCE
    if end in ",;:-\u2013\u2014":
        return PAUSE_CLAUSE
    return PAUSE_PHRASE  # the piece stops mid-phrase, so barely pause at all


def _synth(text: str, voice: str, speed: float, cancel: threading.Event):
    """Runs on the MLX thread. Yields float32 numpy chunks at 24 kHz."""
    v = voice.replace("+", ",")
    for part in split_text(text):
        if cancel.is_set():
            return
        pause = _pause_after(part)
        # generate() returns a part as one array (checked on an M1: one chunk per call), so
        # trimming its pads costs no streaming latency -- there is nothing to hold back.
        for r in MODEL.generate(text=part, voice=v, speed=speed, lang_code=_lang(voice), split_pattern=None):
            audio = np.asarray(r.audio, dtype=np.float32).reshape(-1)
            yield _trim(audio, pause) if TRIM_PIECES else audio
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
