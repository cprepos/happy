"""Streaming STT adapter for the self-hosted Nemotron websocket server.

Protocol (selfhost/VOICE_SERVICES.md, `selfhost/stt/server.py`):

    WS /v1/stream?sample_rate=16000&interim_results=true
      in  binary   PCM16 LE mono 16 kHz
      in  text     {"type": "flush" | "reset" | "close"}
      out text     {"type": "ready" | "partial" | "final" | "closed" | "error", ...}

`partial.text` is the whole segment so far, `final` closes a segment. The agent
session asks for a flush (``manual_flush`` capability) when VAD or the turn
detector says the user stopped, which the server answers with a `final` in ~100 ms.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import time
import uuid
import wave
from urllib.parse import urlencode, urlsplit, urlunsplit

import aiohttp
import numpy as np
from livekit import rtc
from livekit.agents import (
    DEFAULT_API_CONNECT_OPTIONS,
    APIConnectionError,
    APIConnectOptions,
    APIStatusError,
    APITimeoutError,
    stt,
    utils,
)
from livekit.agents.types import NOT_GIVEN, NotGivenOr

logger = logging.getLogger("happy-voice.stt")

SAMPLE_RATE = 16000


def _http_base(url: str) -> str:
    """ws://host:port/v1/stream -> http://host:port"""
    parts = urlsplit(url)
    scheme = {"ws": "http", "wss": "https"}.get(parts.scheme, parts.scheme)
    return urlunsplit((scheme, parts.netloc, "", "", ""))


def _ws_url(url: str) -> str:
    parts = urlsplit(url)
    scheme = {"http": "ws", "https": "wss"}.get(parts.scheme, parts.scheme)
    path = parts.path if parts.path and parts.path != "/" else "/v1/stream"
    return urlunsplit((scheme, parts.netloc, path, "", ""))


def _to_mono_pcm16(frame: rtc.AudioFrame) -> bytes:
    if frame.num_channels == 1:
        return bytes(frame.data)
    samples = np.frombuffer(frame.data, dtype=np.int16).reshape(-1, frame.num_channels)
    return samples.mean(axis=1).astype(np.int16).tobytes()


class NemotronSTT(stt.STT):
    def __init__(
        self,
        *,
        url: str = "ws://127.0.0.1:8090/v1/stream",
        language: str = "en",
        interim_results: bool = True,
        http_session: aiohttp.ClientSession | None = None,
    ) -> None:
        super().__init__(
            capabilities=stt.STTCapabilities(
                streaming=True,
                interim_results=interim_results,
                offline_recognize=True,
                manual_flush=True,
            )
        )
        self._ws_url = _ws_url(url)
        self._http_url = _http_base(url)
        self._language = language
        self._interim_results = interim_results
        self._session = http_session

    @property
    def model(self) -> str:
        return "nemotron-speech-streaming-en-0.6b"

    @property
    def provider(self) -> str:
        return "happy-selfhost"

    def _ensure_session(self) -> aiohttp.ClientSession:
        if self._session is None:
            self._session = utils.http_context.http_session()
        return self._session

    async def _recognize_impl(
        self,
        buffer: utils.AudioBuffer,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        conn_options: APIConnectOptions,
    ) -> stt.SpeechEvent:
        frame = rtc.combine_audio_frames(buffer)
        wav = io.BytesIO()
        with wave.open(wav, "wb") as w:
            w.setnchannels(frame.num_channels)
            w.setsampwidth(2)
            w.setframerate(frame.sample_rate)
            w.writeframes(bytes(frame.data))
        form = aiohttp.FormData()
        form.add_field("file", wav.getvalue(), filename="audio.wav", content_type="audio/wav")
        try:
            async with self._ensure_session().post(
                f"{self._http_url}/v1/audio/transcriptions",
                data=form,
                timeout=aiohttp.ClientTimeout(total=30, sock_connect=conn_options.timeout),
            ) as resp:
                if resp.status != 200:
                    raise APIStatusError(
                        "nemotron transcription failed", status_code=resp.status, body=await resp.text()
                    )
                data = await resp.json()
        except asyncio.TimeoutError as e:
            raise APITimeoutError() from e
        except aiohttp.ClientError as e:
            raise APIConnectionError() from e
        return stt.SpeechEvent(
            type=stt.SpeechEventType.FINAL_TRANSCRIPT,
            request_id=str(uuid.uuid4()),
            alternatives=[stt.SpeechData(language=self._language, text=data.get("text", ""))],
        )

    def stream(
        self,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        conn_options: APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS,
    ) -> NemotronStream:
        return NemotronStream(stt=self, conn_options=conn_options)


class NemotronStream(stt.RecognizeStream):
    def __init__(self, *, stt: NemotronSTT, conn_options: APIConnectOptions) -> None:
        super().__init__(stt=stt, conn_options=conn_options, sample_rate=SAMPLE_RATE)
        self._nstt = stt
        self._speaking = False
        self._request_id = str(uuid.uuid4())

    async def _run(self) -> None:
        query = urlencode(
            {
                "sample_rate": SAMPLE_RATE,
                "interim_results": "true" if self._nstt._interim_results else "false",
                "endpoint_ms": 0,
            }
        )
        url = f"{self._nstt._ws_url}?{query}"
        try:
            ws = await asyncio.wait_for(
                self._nstt._ensure_session().ws_connect(url, heartbeat=20),
                self._conn_options.timeout,
            )
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            raise APIConnectionError(f"failed to connect to STT at {url}") from e

        closing = False

        async def send_task() -> None:
            nonlocal closing
            async for item in self._input_ch:
                if isinstance(item, self._FlushSentinel):
                    logger.debug("stt flush (t=%.3f)", time.time())
                    await ws.send_str(json.dumps({"type": "flush"}))
                else:
                    await ws.send_bytes(_to_mono_pcm16(item))
            closing = True
            await ws.send_str(json.dumps({"type": "close"}))

        async def recv_task() -> None:
            while True:
                msg = await ws.receive()
                if msg.type in (
                    aiohttp.WSMsgType.CLOSE,
                    aiohttp.WSMsgType.CLOSED,
                    aiohttp.WSMsgType.CLOSING,
                ):
                    if closing:
                        return
                    raise APIConnectionError("STT websocket closed unexpectedly")
                if msg.type == aiohttp.WSMsgType.ERROR:
                    raise APIConnectionError(f"STT websocket error: {ws.exception()}")
                if msg.type != aiohttp.WSMsgType.TEXT:
                    continue
                data = json.loads(msg.data)
                kind = data.get("type")
                if kind == "partial":
                    logger.debug("partial seg=%s %r", data.get("segment_id"), data.get("text"))
                    self._on_partial(data.get("text", ""))
                elif kind == "final":
                    self._on_final(data)
                elif kind == "closed":
                    return
                elif kind == "error":
                    logger.error("STT server error: %s", data.get("message"))
                    raise APIConnectionError(f"STT server error: {data.get('message')}")

        tasks = [
            asyncio.create_task(send_task(), name="nemotron-send"),
            asyncio.create_task(recv_task(), name="nemotron-recv"),
        ]
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
            for t in done:
                if t.exception() is not None:
                    raise t.exception()  # type: ignore[misc]
            # the send side finished (input ended): wait for the closing final
            await asyncio.wait_for(tasks[1], timeout=5)
        except asyncio.TimeoutError:
            pass
        except aiohttp.ClientError as e:
            raise APIConnectionError("STT websocket failed") from e
        finally:
            await utils.aio.gracefully_cancel(*tasks)
            await ws.close()

    def _alt(self, text: str) -> list[stt.SpeechData]:
        return [stt.SpeechData(language=self._nstt._language, text=text)]

    def _on_partial(self, text: str) -> None:
        text = text.strip()
        if not text:
            return
        if not self._speaking:
            self._speaking = True
            self._event_ch.send_nowait(
                stt.SpeechEvent(type=stt.SpeechEventType.START_OF_SPEECH, request_id=self._request_id)
            )
        self._event_ch.send_nowait(
            stt.SpeechEvent(
                type=stt.SpeechEventType.INTERIM_TRANSCRIPT,
                request_id=self._request_id,
                alternatives=self._alt(text),
            )
        )

    def _on_final(self, data: dict) -> None:
        text = (data.get("text") or "").strip()
        if text:
            if not self._speaking:
                self._event_ch.send_nowait(
                    stt.SpeechEvent(
                        type=stt.SpeechEventType.START_OF_SPEECH, request_id=self._request_id
                    )
                )
            self._event_ch.send_nowait(
                stt.SpeechEvent(
                    type=stt.SpeechEventType.FINAL_TRANSCRIPT,
                    request_id=self._request_id,
                    alternatives=self._alt(text),
                )
            )
            self._speaking = True
        audio_ms = data.get("audio_ms")
        if audio_ms:
            self._event_ch.send_nowait(
                stt.SpeechEvent(
                    type=stt.SpeechEventType.RECOGNITION_USAGE,
                    request_id=self._request_id,
                    recognition_usage=stt.RecognitionUsage(audio_duration=audio_ms / 1000.0),
                )
            )
        if self._speaking:
            self._event_ch.send_nowait(
                stt.SpeechEvent(type=stt.SpeechEventType.END_OF_SPEECH, request_id=self._request_id)
            )
        self._speaking = False
        self._request_id = str(uuid.uuid4())
        logger.debug("final transcript %r (flush %.0f ms, t=%.3f)", text, data.get("flush_ms") or 0, time.time())
