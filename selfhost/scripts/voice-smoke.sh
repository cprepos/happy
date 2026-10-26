#!/usr/bin/env bash
# Smoke test for the self-hosted voice stack (compose.voice.yml).
#  1. LiveKit: HTTP health + token-based room join that publishes an audio track
#  2. TTS:     Kokoro streaming synthesis, time-to-first-byte
#  3. STT:     stream the TTS audio in real time over the websocket, print partials + final
#  4. LLM:     tool-call completion (sendMessageToSession) + TTFT and tokens/s against the
#              worker's LLM (VOICE_LLM_BASE_URL / VOICE_LLM_MODEL, default: the coder vLLM)
#
# Uses a throwaway venv in ${VOICE_SMOKE_VENV:-~/.cache/happy-voice-smoke-venv}.
# Exit code is non-zero if any check fails.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${VOICE_ENV_FILE:-$HERE/.env.voice}"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (run: make voice-keys)"; exit 1; }
set -a; . "$ENV_FILE"; set +a

VENV="${VOICE_SMOKE_VENV:-$HOME/.cache/happy-voice-smoke-venv}"
if [ ! -x "$VENV/bin/python" ]; then
  echo "== creating smoke-test venv at $VENV"
  if command -v uv >/dev/null 2>&1; then
    uv venv -q -p 3.12 "$VENV" && uv pip install -q -p "$VENV/bin/python" livekit livekit-api websockets httpx numpy scipy
  else
    python3 -m venv "$VENV" && "$VENV/bin/pip" install -q livekit livekit-api websockets httpx numpy scipy
  fi
fi

export SMOKE_OUT="${SMOKE_OUT:-${TMPDIR:-/tmp}/happy-voice-smoke}"
mkdir -p "$SMOKE_OUT"

exec "$VENV/bin/python" -I - <<'PY'
import asyncio, io, json, os, sys, time, wave

import httpx
import numpy as np
from scipy.signal import resample_poly

E = os.environ
OUT = E["SMOKE_OUT"]
STT = f"127.0.0.1:{E.get('STT_PORT', '8090')}"
TTS = f"http://127.0.0.1:{E.get('TTS_PORT', '8880')}"
LLM = (E.get("VOICE_LLM_BASE_URL") or "http://127.0.0.1:9080/v1").rstrip("/")
LLM_NAME = E.get("VOICE_LLM_MODEL") or "coder"
SENTENCE = "Hey, tell Claude to list the files in the source directory and then run the tests."

results: dict[str, str] = {}


def ok(name, msg):
    results[name] = "PASS"
    print(f"[PASS] {name}: {msg}")


def fail(name, msg):
    results[name] = "FAIL"
    print(f"[FAIL] {name}: {msg}")


# ---------------------------------------------------------------- LiveKit
async def livekit_check():
    from livekit import api, rtc

    try:
        r = httpx.get("http://127.0.0.1:7880/", timeout=3)
        assert r.text.strip() == "OK", r.text
    except Exception as e:
        return fail("livekit.health", repr(e))
    ok("livekit.health", "GET / -> OK")

    room_name = f"smoke-{int(time.time())}"
    token = (
        api.AccessToken(E["LIVEKIT_API_KEY"], E["LIVEKIT_API_SECRET"])
        .with_identity("smoke-client")
        .with_name("smoke")
        .with_grants(api.VideoGrants(room_join=True, room=room_name))
        .to_jwt()
    )
    room = rtc.Room()
    t0 = time.perf_counter()
    try:
        await asyncio.wait_for(room.connect("ws://127.0.0.1:7880", token), 15)
        t_join = (time.perf_counter() - t0) * 1000
        src = rtc.AudioSource(48000, 1)
        track = rtc.LocalAudioTrack.create_audio_track("mic", src)
        t1 = time.perf_counter()
        pub = await asyncio.wait_for(room.local_participant.publish_track(track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)), 15)
        t_pub = (time.perf_counter() - t1) * 1000
        frame = rtc.AudioFrame.create(48000, 1, 480)
        for _ in range(50):
            await src.capture_frame(frame)
        lk = api.LiveKitAPI("http://127.0.0.1:7880", E["LIVEKIT_API_KEY"], E["LIVEKIT_API_SECRET"])
        for _ in range(20):  # the server registers the track once media starts flowing
            parts = await lk.room.list_participants(api.ListParticipantsRequest(room=room_name))
            tracks = [t.sid for p in parts.participants for t in p.tracks]
            if pub.sid in tracks:
                break
            await src.capture_frame(frame)
            await asyncio.sleep(0.25)
        await lk.aclose()
        assert pub.sid in tracks, f"published track {pub.sid} not in {tracks}"
        ok("livekit.room", f"joined {room_name} in {t_join:.0f} ms, published audio track in {t_pub:.0f} ms (ICE connected), server sees {len(parts.participants)} participant(s)")
    except Exception as e:
        fail("livekit.room", repr(e))
    finally:
        await room.disconnect()


# ---------------------------------------------------------------- TTS
def tts_check():
    body = {"model": "kokoro", "input": SENTENCE, "voice": "af_heart", "response_format": "pcm", "stream": True, "speed": 1.0}
    try:
        httpx.post(f"{TTS}/v1/audio/speech", json={**body, "input": "warm up"}, timeout=60).raise_for_status()
        t0 = time.perf_counter()
        ttfb = None
        buf = bytearray()
        with httpx.stream("POST", f"{TTS}/v1/audio/speech", json=body, timeout=60) as r:
            r.raise_for_status()
            for chunk in r.iter_bytes():
                if chunk and ttfb is None:
                    ttfb = (time.perf_counter() - t0) * 1000
                buf.extend(chunk)
        total = (time.perf_counter() - t0) * 1000
        pcm24 = np.frombuffer(bytes(buf[: len(buf) // 2 * 2]), dtype="<i2")
        dur = pcm24.size / 24000
        assert dur > 1.0, f"audio too short: {dur:.2f}s"
        with wave.open(os.path.join(OUT, "tts_24k.wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(pcm24.tobytes())
        pcm16 = resample_poly(pcm24.astype(np.float32), 2, 3)
        pcm16 = np.clip(pcm16, -32768, 32767).astype("<i2")
        with wave.open(os.path.join(OUT, "tts_16k.wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(pcm16.tobytes())
        ok("tts.stream", f"TTFB {ttfb:.0f} ms, total {total:.0f} ms for {dur:.2f}s audio (RTF {total/1000/dur:.3f}) -> {OUT}/tts_16k.wav")
        return pcm16
    except Exception as e:
        fail("tts.stream", repr(e))
        return None


# ---------------------------------------------------------------- STT
def words(s):
    return [w.strip(".,!?;:").lower() for w in s.split() if w.strip(".,!?;:")]


def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r))


async def stt_check(pcm16):
    import websockets

    try:
        health = httpx.get(f"http://{STT}/health", timeout=3).json()
    except Exception as e:
        return fail("stt.health", repr(e))
    ok("stt.health", json.dumps(health))
    if pcm16 is None:
        return fail("stt.stream", "no TTS audio to transcribe")
    # 0.5 s of leading/trailing silence like a real mic
    sil = np.zeros(8000, dtype="<i2")
    audio = np.concatenate([sil, pcm16, sil])
    frame = 320  # 20 ms
    try:
        async with websockets.connect(f"ws://{STT}/v1/stream?sample_rate=16000", max_size=None) as ws:
            ready = json.loads(await ws.recv())
            assert ready["type"] == "ready", ready
            partials = []
            final = {}
            t_start = time.perf_counter()

            async def reader():
                async for m in ws:
                    msg = json.loads(m)
                    msg["_t"] = time.perf_counter() - t_start
                    if msg["type"] == "partial":
                        partials.append(msg)
                    elif msg["type"] == "final":
                        final.update(msg)
                        return

            rt = asyncio.create_task(reader())
            for i in range(0, audio.size, frame):
                await ws.send(audio[i : i + frame].tobytes())
                target = (i + frame) / 16000
                delay = target - (time.perf_counter() - t_start)
                if delay > 0:
                    await asyncio.sleep(delay)  # real-time pacing
            t_flush = time.perf_counter() - t_start
            await ws.send(json.dumps({"type": "flush"}))
            await asyncio.wait_for(rt, 10)
            await ws.send(json.dumps({"type": "close"}))
        first = partials[0] if partials else None
        # partial lag: wall-clock arrival minus the audio position it covers
        lags = [p["_t"] * 1000 - p["audio_ms"] for p in partials]
        w = wer(SENTENCE, final.get("text", ""))
        print(f"       partials ({len(partials)}): " + " | ".join(p["text"] for p in partials[:: max(1, len(partials) // 6)]))
        print(f"       final: {final.get('text')!r}  (WER {w:.2%})")
        msg = (
            f"{len(partials)} partials, partial lag behind audio avg {sum(lags)/len(lags):.0f} ms / max {max(lags):.0f} ms, "
            f"final {(final['_t']-t_flush)*1000:.0f} ms after flush (end of audio)"
            if first else "no partials"
        )
        (ok if partials and w < 0.25 else fail)("stt.stream", msg)
    except Exception as e:
        fail("stt.stream", repr(e))

    # file endpoint
    try:
        bio = io.BytesIO()
        with wave.open(bio, "wb") as wv:
            wv.setnchannels(1); wv.setsampwidth(2); wv.setframerate(16000); wv.writeframes(pcm16.tobytes())
        t0 = time.perf_counter()
        r = httpx.post(f"http://{STT}/v1/audio/transcriptions", files={"file": ("a.wav", bio.getvalue(), "audio/wav")}, timeout=60)
        r.raise_for_status()
        j = r.json()
        (ok if wer(SENTENCE, j["text"]) < 0.25 else fail)("stt.file", f"{(time.perf_counter()-t0)*1000:.0f} ms for {j['duration']}s: {j['text']!r}")
    except Exception as e:
        fail("stt.file", repr(e))


# ---------------------------------------------------------------- LLM
TOOLS = [
    {"type": "function", "function": {
        "name": "sendMessageToSession",
        "description": "Send a message to a coding agent session (Claude Code / Codex) on the user's machine.",
        "parameters": {"type": "object", "properties": {
            "sessionId": {"type": "string", "description": "ID of the target session"},
            "message": {"type": "string", "description": "The message to send, phrased as an instruction to the coding agent"}},
            "required": ["sessionId", "message"]}}},
    {"type": "function", "function": {
        "name": "processPermissionRequest",
        "description": "Approve or deny a pending permission request from a session.",
        "parameters": {"type": "object", "properties": {
            "requestId": {"type": "string"},
            "decision": {"type": "string", "enum": ["allow", "deny"]}},
            "required": ["requestId", "decision"]}}},
]
SYSTEM = ("You are a concise voice assistant that controls coding sessions. The active session is "
          "sessionId 'sess_42' (project: happy). Use tools when the user asks you to tell the agent something.")


def llm_check():
    try:
        models = httpx.get(f"{LLM}/models", timeout=5).json()
        ok("llm.models", ", ".join(m["id"] for m in models["data"]))
    except Exception as e:
        return fail("llm.models", repr(e))

    # tool call (streamed, to measure TTFT of the tool call)
    try:
        body = {"model": LLM_NAME, "stream": True, "temperature": 0.2, "max_tokens": 200,
                "stream_options": {"include_usage": True},
                "chat_template_kwargs": {"enable_thinking": False},
                "messages": [{"role": "system", "content": SYSTEM},
                             {"role": "user", "content": "Tell Claude to list the files in the src directory."}],
                "tools": TOOLS, "tool_choice": "auto"}
        t0 = time.perf_counter(); ttft = None
        name, args, content = None, "", ""
        with httpx.stream("POST", f"{LLM}/chat/completions", json=body, timeout=120) as r:
            r.raise_for_status()
            for line in r.iter_lines():
                if not line.startswith("data: ") or line == "data: [DONE]":
                    continue
                ch = json.loads(line[6:])
                if not ch.get("choices"):
                    continue
                d = ch["choices"][0]["delta"]
                if (d.get("tool_calls") or d.get("content")) and ttft is None:
                    ttft = (time.perf_counter() - t0) * 1000
                for tc in d.get("tool_calls") or []:
                    f = tc.get("function", {})
                    name = f.get("name") or name
                    args += f.get("arguments") or ""
                content += d.get("content") or ""
        total = (time.perf_counter() - t0) * 1000
        a = json.loads(args) if args else {}
        good = name == "sendMessageToSession" and a.get("sessionId") == "sess_42" and "src" in a.get("message", "").lower()
        (ok if good else fail)("llm.toolcall", f"{name}({json.dumps(a)}) first delta {ttft:.0f} ms, done {total:.0f} ms" + (f" content={content!r}" if content else ""))
    except Exception as e:
        fail("llm.toolcall", repr(e))

    # plain streamed reply: TTFT and decode speed
    try:
        body = {"model": LLM_NAME, "stream": True, "temperature": 0.7, "max_tokens": 300,
                "stream_options": {"include_usage": True},
                "chat_template_kwargs": {"enable_thinking": False},
                "messages": [{"role": "system", "content": SYSTEM},
                             {"role": "user", "content": "Explain in a few short paragraphs what a git rebase does."}]}
        t0 = time.perf_counter(); ttft = None; t_last = None; usage = None; text = ""
        with httpx.stream("POST", f"{LLM}/chat/completions", json=body, timeout=120) as r:
            r.raise_for_status()
            for line in r.iter_lines():
                if not line.startswith("data: ") or line == "data: [DONE]":
                    continue
                ch = json.loads(line[6:])
                if ch.get("usage"):
                    usage = ch["usage"]
                if ch.get("choices") and ch["choices"][0]["delta"].get("content"):
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    t_last = time.perf_counter() - t0
                    text += ch["choices"][0]["delta"]["content"]
        n = usage["completion_tokens"]
        tps = (n - 1) / (t_last - ttft) if t_last and t_last > ttft else float("nan")
        thinking = "<think>" in text
        (ok if not thinking else fail)("llm.stream", f"TTFT {ttft*1000:.0f} ms, {n} tokens, {tps:.1f} tok/s decode, prompt {usage['prompt_tokens']} tokens" + (" (THINKING LEAKED)" if thinking else ""))
    except Exception as e:
        fail("llm.stream", repr(e))


async def main():
    only = set(filter(None, E.get("SMOKE_ONLY", "").split(",")))
    if not only or "livekit" in only:
        await livekit_check()
    pcm = None
    if not only or "tts" in only or "stt" in only:
        pcm = tts_check()
    if not only or "stt" in only:
        await stt_check(pcm)
    if not only or "llm" in only:
        llm_check()
    failed = [k for k, v in results.items() if v != "PASS"]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed" + (f"; failed: {', '.join(failed)}" if failed else ""))
    sys.exit(1 if failed else 0)


asyncio.run(main())
PY
