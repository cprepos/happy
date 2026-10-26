"""Local voice test page: static files plus a same-origin proxy to the voice services.

Bound to 127.0.0.1 only (reach it over an SSH tunnel). Routes:
  GET  /                    index.html
  GET  /api/config          service URLs and the LLM model name
  GET  /api/tts/voices      -> TTS  GET  /v1/audio/voices
  POST /api/tts/speech      -> TTS  POST /v1/audio/speech        (streamed through)
  GET  /api/stt/health      -> STT  GET  /health
  WS   /api/stt/stream      -> STT  WS   /v1/stream              (bidirectional relay)
  POST /api/llm/chat        -> LLM  POST /v1/chat/completions    (streamed through)
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path

import aiohttp
from aiohttp import WSMsgType, web

HERE = Path(__file__).resolve().parent
HOST = "127.0.0.1"  # never exposed beyond loopback
PORT = int(os.environ.get("VOICE_TRY_PORT", "8899"))
TTS = f"http://127.0.0.1:{os.environ.get('TTS_PORT', '8880')}"
STT = f"http://127.0.0.1:{os.environ.get('STT_PORT', '8090')}"
LLM = f"http://127.0.0.1:{os.environ.get('LLM_PORT', '8000')}"
LLM_NAME = os.environ.get("LLM_SERVED_NAME", "voice-llm")


async def index(_req: web.Request) -> web.FileResponse:
    return web.FileResponse(HERE / "index.html", headers={"Cache-Control": "no-store"})


async def config(_req: web.Request) -> web.Response:
    return web.json_response({"llm_model": LLM_NAME, "tts": TTS, "stt": STT, "llm": LLM})


async def _passthrough(req: web.Request, method: str, url: str) -> web.StreamResponse:
    session: aiohttp.ClientSession = req.app["http"]
    body = await req.read() if req.can_read_body else None
    headers = {"Content-Type": req.headers.get("Content-Type", "application/json")} if body else {}
    try:
        upstream = await session.request(method, url, data=body, headers=headers)
    except aiohttp.ClientError as e:
        return web.json_response({"error": f"upstream unavailable: {e}"}, status=502)
    async with upstream:
        resp = web.StreamResponse(status=upstream.status)
        resp.content_type = upstream.content_type
        resp.headers["Cache-Control"] = "no-store"
        resp.headers["X-Accel-Buffering"] = "no"
        await resp.prepare(req)
        async for chunk in upstream.content.iter_any():
            await resp.write(chunk)
        await resp.write_eof()
        return resp


async def tts_voices(req: web.Request):
    return await _passthrough(req, "GET", f"{TTS}/v1/audio/voices")


async def tts_speech(req: web.Request):
    return await _passthrough(req, "POST", f"{TTS}/v1/audio/speech")


async def stt_health(req: web.Request):
    return await _passthrough(req, "GET", f"{STT}/health")


async def llm_chat(req: web.Request):
    return await _passthrough(req, "POST", f"{LLM}/v1/chat/completions")


async def stt_stream(req: web.Request) -> web.WebSocketResponse:
    client = web.WebSocketResponse(max_msg_size=4 * 1024 * 1024)
    await client.prepare(req)
    session: aiohttp.ClientSession = req.app["http"]
    target = f"{STT.replace('http', 'ws', 1)}/v1/stream?{req.query_string}"
    try:
        upstream = await session.ws_connect(target, max_msg_size=4 * 1024 * 1024)
    except aiohttp.ClientError as e:
        await client.send_json({"type": "error", "message": f"stt unavailable: {e}"})
        await client.close()
        return client

    async def pump(src, dst):
        async for msg in src:
            if msg.type == WSMsgType.BINARY:
                await dst.send_bytes(msg.data)
            elif msg.type == WSMsgType.TEXT:
                await dst.send_str(msg.data)
            else:
                break

    tasks = [asyncio.create_task(pump(client, upstream)), asyncio.create_task(pump(upstream, client))]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for t in tasks:
            t.cancel()
        await upstream.close()
        await client.close()
    return client


async def _startup(app: web.Application) -> None:
    app["http"] = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, sock_connect=5))


async def _cleanup(app: web.Application) -> None:
    await app["http"].close()


def make_app() -> web.Application:
    app = web.Application(client_max_size=16 * 1024 * 1024)
    app.on_startup.append(_startup)
    app.on_cleanup.append(_cleanup)
    app.router.add_get("/", index)
    app.router.add_get("/api/config", config)
    app.router.add_get("/api/tts/voices", tts_voices)
    app.router.add_post("/api/tts/speech", tts_speech)
    app.router.add_get("/api/stt/health", stt_health)
    app.router.add_get("/api/stt/stream", stt_stream)
    app.router.add_post("/api/llm/chat", llm_chat)
    return app


if __name__ == "__main__":
    print(f"voice test page: http://{HOST}:{PORT}/  (tunnel: ssh -L {PORT}:127.0.0.1:{PORT} <user>@<host>)", flush=True)
    web.run_app(make_app(), host=HOST, port=PORT, print=None)
