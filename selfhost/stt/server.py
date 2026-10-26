"""Streaming STT server for NVIDIA Nemotron Speech Streaming (cache-aware FastConformer RNNT).

Endpoints (see selfhost/VOICE_SERVICES.md for the full contract):
  GET  /health                     -> {"status":"ok", ...}
  WS   /v1/stream                  -> binary PCM16LE mono 16 kHz in, JSON partial/final out
  POST /v1/audio/transcriptions    -> OpenAI-style file transcription (multipart "file")

The model is loaded once; every websocket gets its own encoder cache + decoder state, and
GPU steps from all streams are serialized through one lock (a step is ~10-20 ms).
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import time
from dataclasses import dataclass, field

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, File, Form, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("stt")

MODEL_NAME = os.environ.get("STT_MODEL", "nvidia/nemotron-speech-streaming-en-0.6b")
# att_context_size right context, in 80 ms encoder frames: 0 -> 80 ms chunks, 1 -> 160 ms, 6 -> 560 ms, 13 -> 1120 ms
RIGHT_CONTEXT = int(os.environ.get("STT_RIGHT_CONTEXT", "1"))
LEFT_CONTEXT = int(os.environ.get("STT_LEFT_CONTEXT", "70"))
DEFAULT_ENDPOINT_MS = int(os.environ.get("STT_ENDPOINT_MS", "0"))
SAMPLE_RATE = 16000
LOG_MEL_ZERO = -16.635532333438686  # log(2^-24): preprocessor output for digital silence

app = FastAPI(title="nemotron-streaming-stt")


class Engine:
    def __init__(self) -> None:
        import nemo.collections.asr as nemo_asr
        from omegaconf import open_dict

        t0 = time.time()
        self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        model = nemo_asr.models.ASRModel.from_pretrained(model_name=MODEL_NAME, map_location=self.device)
        model.encoder.set_default_att_context_size([LEFT_CONTEXT, RIGHT_CONTEXT])

        # Deterministic features for streaming: no dither, no padding.
        cfg = model.cfg.preprocessor
        with open_dict(cfg):
            cfg.dither = 0.0
            cfg.pad_to = 0
        self.preprocessor = model.from_config_dict(cfg).to(self.device)
        self.preprocessor.eval()

        decoding_cfg = model.cfg.decoding
        with open_dict(decoding_cfg):
            decoding_cfg.strategy = "greedy_batch"
            decoding_cfg.preserve_alignments = False
            if "greedy" in decoding_cfg:
                decoding_cfg.greedy.max_symbols = 10
                # CUDA graphs in the greedy decoder do not play well with per-step streaming state.
                decoding_cfg.greedy.loop_labels = True
                decoding_cfg.greedy.use_cuda_graph_decoder = False
            if "fused_batch_size" in decoding_cfg:
                decoding_cfg.fused_batch_size = -1
        model.change_decoding_strategy(decoding_cfg)
        model.eval()
        self.model = model

        scfg = model.encoder.streaming_cfg
        _second = lambda v: v[1] if isinstance(v, (list, tuple)) else v  # noqa: E731  [first-chunk, steady-state]
        self.pre_encode_cache_size = _second(scfg.pre_encode_cache_size)  # mel frames of left feature context
        self.chunk_frames = _second(scfg.chunk_size)  # mel frames per encoder step
        self.drop_extra_pre_encoded = scfg.drop_extra_pre_encoded
        self.num_features = cfg.features
        self.hop = int(cfg.window_stride * SAMPLE_RATE)  # 160 samples (10 ms)
        self.chunk_samples = self.chunk_frames * self.hop
        self.chunk_ms = self.chunk_samples * 1000 // SAMPLE_RATE
        self.buffer_frames = self.pre_encode_cache_size + self.chunk_frames
        self.lock = asyncio.Lock()
        self.load_s = time.time() - t0
        log.info(
            "loaded %s on %s in %.1fs; att_context=[%d,%d] chunk=%dms (%d mel frames) pre_encode_cache=%d drop_extra=%s",
            MODEL_NAME, self.device, self.load_s, LEFT_CONTEXT, RIGHT_CONTEXT, self.chunk_ms, self.chunk_frames,
            self.pre_encode_cache_size, self.drop_extra_pre_encoded,
        )

    def new_state(self) -> "StreamState":
        c_ch, c_t, c_len = self.model.encoder.get_initial_cache_state(batch_size=1)
        return StreamState(
            cache_last_channel=c_ch,
            cache_last_time=c_t,
            cache_last_channel_len=c_len,
            # Same scheme as NeMo's BatchedCacheFeatureBufferer: a rolling log-mel buffer of
            # (pre-encode cache + chunk) frames, initialised to the log-mel value of silence.
            feat_buffer=torch.full((1, self.num_features, self.buffer_frames), LOG_MEL_ZERO, device=self.device),
            lookback=np.zeros(self.hop, dtype=np.float32),
        )

    @torch.inference_mode()
    def transcribe_file(self, audio: np.ndarray) -> str:
        out = self.model.transcribe([audio], batch_size=1, verbose=False)
        return _hyp_text(out)

    @torch.inference_mode()
    def step(self, st: "StreamState", chunk: np.ndarray, last: bool = False) -> str:
        """Feed exactly one chunk (float32, chunk_samples long). Returns the full segment text so far."""
        # One hop of audio look-back so the first STFT frame of the chunk has real context.
        audio_np = np.concatenate([st.lookback, chunk])
        st.lookback = chunk[-self.hop:]
        audio = torch.from_numpy(audio_np).unsqueeze(0).to(self.device)
        length = torch.tensor([audio.shape[1]], device=self.device)
        feats, _ = self.preprocessor(input_signal=audio, length=length)
        feats = feats[:, :, : self.chunk_frames + 1][:, :, -self.chunk_frames:]
        st.feat_buffer = torch.cat([st.feat_buffer[:, :, self.chunk_frames:], feats], dim=-1)
        feats_len = torch.tensor([self.buffer_frames], device=self.device)

        out = self.model.conformer_stream_step(
            processed_signal=st.feat_buffer,
            processed_signal_length=feats_len,
            cache_last_channel=st.cache_last_channel,
            cache_last_time=st.cache_last_time,
            cache_last_channel_len=st.cache_last_channel_len,
            keep_all_outputs=last,
            previous_hypotheses=st.hyps,
            previous_pred_out=st.pred_out,
            drop_extra_pre_encoded=self.drop_extra_pre_encoded,
            return_transcription=True,
        )
        (st.pred_out, texts, st.cache_last_channel, st.cache_last_time, st.cache_last_channel_len, st.hyps) = out
        st.steps += 1
        return _hyp_text(texts)


def _hyp_text(texts) -> str:
    if not texts:
        return ""
    t = texts[0]
    if hasattr(t, "text"):
        t = t.text
    if isinstance(t, (list, tuple)):
        t = t[0] if t else ""
    return (t or "").strip()


@dataclass
class StreamState:
    cache_last_channel: torch.Tensor
    cache_last_time: torch.Tensor
    cache_last_channel_len: torch.Tensor
    feat_buffer: torch.Tensor
    lookback: np.ndarray
    hyps: object = None
    pred_out: object = None
    steps: int = 0
    pending: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float32))
    text: str = ""
    audio_samples: int = 0  # audio fed into this segment


ENGINE: Engine | None = None


@app.on_event("startup")
async def _startup() -> None:
    global ENGINE
    loop = asyncio.get_running_loop()
    ENGINE = await loop.run_in_executor(None, Engine)
    # Warm up kernels so the first real request is fast.
    st = ENGINE.new_state()
    for _ in range(3):
        ENGINE.step(st, np.zeros(ENGINE.chunk_samples, dtype=np.float32))
    log.info("warmup done")


@app.get("/health")
async def health():
    if ENGINE is None:
        return JSONResponse({"status": "loading"}, status_code=503)
    return {
        "status": "ok",
        "model": MODEL_NAME,
        "sample_rate": SAMPLE_RATE,
        "chunk_ms": ENGINE.chunk_ms,
        "att_context_size": [LEFT_CONTEXT, RIGHT_CONTEXT],
        "device": str(ENGINE.device),
    }


async def _run_step(st: StreamState, chunk: np.ndarray) -> str:
    assert ENGINE is not None
    async with ENGINE.lock:
        return await asyncio.get_running_loop().run_in_executor(None, ENGINE.step, st, chunk)


async def _feed(st: StreamState, pcm: np.ndarray) -> list[str]:
    """Append audio, run all complete chunks. Returns texts after each step."""
    assert ENGINE is not None
    st.pending = np.concatenate([st.pending, pcm]) if st.pending.size else pcm
    outs = []
    n = ENGINE.chunk_samples
    while st.pending.size >= n:
        chunk, st.pending = st.pending[:n], st.pending[n:]
        st.audio_samples += n
        outs.append(await _run_step(st, chunk))
    return outs


async def _finish(st: StreamState) -> str:
    """Flush: pad the tail plus one lookahead window of silence so the last words are emitted."""
    assert ENGINE is not None
    n = ENGINE.chunk_samples
    tail = st.pending
    st.pending = np.zeros(0, dtype=np.float32)
    pad = (-tail.size) % n
    silence = np.zeros(pad + n, dtype=np.float32)  # one chunk covers the right context
    text = st.text
    for t in await _feed(st, np.concatenate([tail, silence])):
        text = t
    return text


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

    st = ENGINE.new_state()
    segment = 0
    last_change_samples = 0
    t_seg = time.monotonic()
    await ws.send_json({"type": "ready", "model": MODEL_NAME, "sample_rate": SAMPLE_RATE, "chunk_ms": ENGINE.chunk_ms})

    async def emit_final() -> None:
        nonlocal st, segment, last_change_samples, t_seg
        t0 = time.monotonic()
        text = await _finish(st)
        await ws.send_json({
            "type": "final",
            "segment_id": segment,
            "text": text,
            "audio_ms": st.audio_samples * 1000 // SAMPLE_RATE,
            "flush_ms": round((time.monotonic() - t0) * 1000, 1),
        })
        segment += 1
        st = ENGINE.new_state()
        last_change_samples = 0
        t_seg = time.monotonic()

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
                            await ws.send_json({
                                "type": "partial",
                                "segment_id": segment,
                                "text": text,
                                "audio_ms": st.audio_samples * 1000 // SAMPLE_RATE,
                            })
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
                    st = ENGINE.new_state()
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
async def transcribe(file: UploadFile = File(...), model: str = Form(default=MODEL_NAME), response_format: str = Form(default="json")):
    assert ENGINE is not None
    raw = await file.read()
    audio, sr = sf.read(io.BytesIO(raw), dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        import librosa

        audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE).astype(np.float32)
    t0 = time.monotonic()
    # Whole-file requests use offline (full-utterance) decoding: faster and slightly more accurate.
    async with ENGINE.lock:
        text = await asyncio.get_running_loop().run_in_executor(None, ENGINE.transcribe_file, audio)
    dur = audio.size / SAMPLE_RATE
    elapsed = time.monotonic() - t0
    if response_format == "text":
        from fastapi.responses import PlainTextResponse

        return PlainTextResponse(text)
    return {"text": text, "duration": round(dur, 3), "processing_s": round(elapsed, 3)}
