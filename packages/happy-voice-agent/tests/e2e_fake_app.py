"""End-to-end test: a headless LiveKit client that plays the part of the app.

It mints its own token (with agent dispatch to `happy-voice`), joins a fresh room, answers the
`happy.getConfig` RPC, records `sendMessageToSession` / `processPermissionRequest` RPCs, and
speaks into the room with WAVs synthesized by the Kokoro TTS. It checks the contract behaviour
end to end against the running worker and services and reports turn latency.

    python tests/e2e_fake_app.py [--env ../../selfhost/.env.voice] [--livekit ws://127.0.0.1:7880]

Exit code 0 when every check passes.
"""

from __future__ import annotations

import argparse
import asyncio
import difflib
import json
import os
import re
import statistics
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

import aiohttp
import numpy as np
from livekit import api, rtc

HERE = Path(__file__).resolve().parent
DEFAULT_ENV = HERE.parents[2] / "selfhost" / ".env.voice"

SR_IN = 24000  # Kokoro PCM rate; published as is
FRAME_MS = 10
MIC_QUEUE_MS = 400
MIC_CUSHION_S = 0.2
SPEECH_RMS = 400  # int16 RMS above which a received agent frame counts as speech

SESSION_ID = "sess_e2e_42"
REQUEST_ID = "req_7f3a9c"

UTTERANCES = {
    "list_files": "Hi Happy, can you tell Claude to list the files in the source folder?",
    "about": "Happy, what is this session about?",
    "allow": "Yes, allow it.",
    "thanks": "Happy, how many sessions do I have open right now?",
}

SYSTEM_PROMPT_APP = (
    "You are a voice interface for Happy - a coding agent orchestrator application on mobile and web. "
    "You are a friendly woman, but very direct and to the point.\n\n"
    "# Runtime counters\n- onboarding_prompt_load_count: 0\n- voice_message_count: 0\n\n"
    "# Conversation history so far\nAvailable sessions:\n"
    f'- {SESSION_ID}: "Refactor the auth module of the web server"\n- sess_other_7: "Fix dark mode"\n\n'
    "CURRENT SESSION:\n\n"
    f"# Session ID: {SESSION_ID}\n\n# Project path: /home/dev/webserver\n\n"
    "# Session summary:\nRefactor the auth module of the web server\n\n"
    "## Our interaction history so far\n\n"
    f"History of messages in session: {SESSION_ID}\n\n"
    "User sent message: \n<text>Please refactor the login handler to use the new token service.</text>\n\n"
    "Claude Code: \n<text>I refactored the login handler. It now calls TokenService.issue and all 42 tests pass.</text>"
)

CONFIG = {
    "systemPrompt": SYSTEM_PROMPT_APP,
    "firstMessage": "Hi, Happy here",
    "initialContext": "",
    "language": "en",
    "sessionId": SESSION_ID,
}


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def norm_words(s: str) -> list[str]:
    return re.sub(r"[^a-z0-9' ]+", " ", s.lower()).split()


def similarity(a: str, b: str) -> float:
    return difflib.SequenceMatcher(None, norm_words(a), norm_words(b)).ratio()


async def synthesize(http: aiohttp.ClientSession, tts_url: str, text: str, voice: str) -> np.ndarray:
    async with http.post(
        f"{tts_url}/audio/speech",
        json={"model": "kokoro", "input": text, "voice": voice, "response_format": "pcm", "stream": False},
        timeout=aiohttp.ClientTimeout(total=60),
    ) as r:
        r.raise_for_status()
        pcm = await r.read()
    return np.frombuffer(pcm, dtype=np.int16).copy()


@dataclass
class Turn:
    name: str
    speech_end: float
    first_audio: float | None = None


@dataclass
class World:
    rpc_calls: list[tuple[float, str, dict]] = field(default_factory=list)
    config_requests: int = 0
    transcripts: list[tuple[float, str, str, bool]] = field(default_factory=list)  # t, who, text, final
    agent_states: list[tuple[float, str]] = field(default_factory=list)
    speech_onsets: list[float] = field(default_factory=list)  # agent audio onsets
    agent_identity: str = ""
    last_loud: float = 0.0
    in_speech: bool = False


class Mic:
    """Publishes a continuous mono track: silence unless an utterance is playing, paced in real time."""

    def __init__(self) -> None:
        self.source = rtc.AudioSource(SR_IN, 1, queue_size_ms=MIC_QUEUE_MS)
        self._queue: asyncio.Queue[tuple[np.ndarray, asyncio.Future]] = asyncio.Queue()
        self._task: asyncio.Task | None = None

    def start(self) -> None:
        self._task = asyncio.create_task(self._run())

    async def _run(self) -> None:
        n = SR_IN * FRAME_MS // 1000
        silence = np.zeros(n, dtype=np.int16)
        current: np.ndarray | None = None
        pos = 0
        fut: asyncio.Future | None = None
        while True:
            if current is None and not self._queue.empty():
                current, fut = self._queue.get_nowait()
                pos = 0
            if current is not None:
                chunk = current[pos : pos + n]
                if len(chunk) < n:
                    chunk = np.concatenate([chunk, np.zeros(n - len(chunk), dtype=np.int16)])
                pos += n
            else:
                chunk = silence
            frame = rtc.AudioFrame(chunk.tobytes(), SR_IN, 1, n)
            await self.source.capture_frame(frame)
            if current is not None and pos >= len(current):
                current = None
                if fut and not fut.done():
                    # the last frame is queued; it plays out after what is still buffered
                    fut.set_result(time.time() + self.source.queued_duration)
            # Keep a cushion of buffered audio so event-loop hiccups never starve the track
            # (an underrun turns into a silent gap that splits the utterance for the VAD).
            excess = self.source.queued_duration - MIC_CUSHION_S
            if excess > 0:
                await asyncio.sleep(excess)

    async def say(self, pcm: np.ndarray) -> float:
        """Plays pcm; returns the wall time of the end of speech (last loud sample)."""
        fut = asyncio.get_running_loop().create_future()
        await self._queue.put((pcm, fut))
        end_of_buffer = await fut
        # trailing quiet samples of the TTS clip
        loud = np.nonzero(np.abs(pcm) > 300)[0]
        tail = (len(pcm) - (loud[-1] if len(loud) else len(pcm))) / SR_IN
        return end_of_buffer - tail


class Checks:
    def __init__(self) -> None:
        self.results: list[tuple[str, bool, str]] = []

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.results.append((name, ok, detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}{(': ' + detail) if detail else ''}", flush=True)
        return ok


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default=str(DEFAULT_ENV))
    ap.add_argument("--livekit", default=os.environ.get("LIVEKIT_URL", "ws://127.0.0.1:7880"))
    ap.add_argument("--tts", default=os.environ.get("TTS_URL", "http://127.0.0.1:8880/v1"))
    ap.add_argument("--voice", default="am_michael")
    ap.add_argument("--agent-name", default="happy-voice")
    args = ap.parse_args()

    env = load_env(Path(args.env))
    key, secret = env["LIVEKIT_API_KEY"], env["LIVEKIT_API_SECRET"]
    room_name = f"happy-voice-e2e-{uuid.uuid4().hex[:8]}"
    identity = "user-e2e"
    checks = Checks()
    world = World()

    async with aiohttp.ClientSession() as http:
        print(f"synthesizing {len(UTTERANCES)} utterances with Kokoro ({args.voice})", flush=True)
        clips = {k: await synthesize(http, args.tts, v, args.voice) for k, v in UTTERANCES.items()}

    token = (
        api.AccessToken(key, secret)
        .with_identity(identity)
        .with_name("E2E fake app")
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=room_name,
                can_publish=True,
                can_subscribe=True,
                can_publish_data=True,
            )
        )
        .with_room_config(
            api.RoomConfiguration(agents=[api.RoomAgentDispatch(agent_name=args.agent_name)])
        )
        .to_jwt()
    )

    room = rtc.Room()


    async def _get_config(data: rtc.RpcInvocationData) -> str:
        world.config_requests += 1
        print(f"  <- happy.getConfig from {data.caller_identity}", flush=True)
        return json.dumps(CONFIG)


    async def _send_message(data: rtc.RpcInvocationData) -> str:
        payload = json.loads(data.payload)
        world.rpc_calls.append((time.time(), "sendMessageToSession", payload))
        print(f"  <- sendMessageToSession {payload}", flush=True)
        return "sent [DO NOT say anything else, simply say 'sent']"


    async def _permission(data: rtc.RpcInvocationData) -> str:
        payload = json.loads(data.payload)
        world.rpc_calls.append((time.time(), "processPermissionRequest", payload))
        print(f"  <- processPermissionRequest {payload}", flush=True)
        if payload.get("requestId") != REQUEST_ID:
            return "error (permission request not found)"
        return "done [DO NOT say anything else, simply say 'done']"

    def on_transcription(reader: rtc.TextStreamReader, participant_identity: str) -> None:
        attrs = reader.info.attributes or {}

        async def read() -> None:
            text = await reader.read_all()
            final = attrs.get("lk.transcription_final") == "true"
            track = attrs.get("lk.transcribed_track_id", "")
            who = "agent"
            pub = room.local_participant.track_publications.get(track)
            if pub is not None:
                who = "user"
            world.transcripts.append((time.time(), who, text, final))

        asyncio.create_task(read())

    room.register_text_stream_handler("lk.transcription", on_transcription)

    def watch_state(p: rtc.Participant) -> None:
        st = p.attributes.get("lk.agent.state")
        if st and (not world.agent_states or world.agent_states[-1][1] != st):
            world.agent_states.append((time.time(), st))
            print(f"  agent state: {st}", flush=True)

    @room.on("participant_attributes_changed")
    def _attrs(changed: dict, p: rtc.Participant) -> None:
        if p.kind == rtc.ParticipantKind.PARTICIPANT_KIND_AGENT:
            watch_state(p)

    agent_joined = asyncio.Event()

    @room.on("participant_connected")
    def _joined(p: rtc.RemoteParticipant) -> None:
        if p.kind == rtc.ParticipantKind.PARTICIPANT_KIND_AGENT:
            world.agent_identity = p.identity
            agent_joined.set()
            watch_state(p)

    async def consume_audio(track: rtc.Track) -> None:
        stream = rtc.AudioStream(track, sample_rate=24000, num_channels=1)
        async for ev in stream:
            samples = np.frombuffer(ev.frame.data, dtype=np.int16)
            rms = float(np.sqrt(np.mean(samples.astype(np.float32) ** 2))) if len(samples) else 0.0
            now = time.time()
            if rms > SPEECH_RMS:
                if not world.in_speech:
                    world.in_speech = True
                    world.speech_onsets.append(now)
                world.last_loud = now
            elif world.in_speech and now - world.last_loud > 0.6:
                world.in_speech = False

    @room.on("track_subscribed")
    def _sub(track: rtc.Track, pub: rtc.RemoteTrackPublication, p: rtc.RemoteParticipant) -> None:
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            print(f"  subscribed to audio of {p.identity}", flush=True)
            asyncio.create_task(consume_audio(track))

    t_connect = time.time()
    await room.connect(args.livekit, token)
    lp = room.local_participant
    lp.register_rpc_method("happy.getConfig", _get_config)
    lp.register_rpc_method("sendMessageToSession", _send_message)
    lp.register_rpc_method("processPermissionRequest", _permission)
    print(f"joined {room_name} in {time.time() - t_connect:.2f}s", flush=True)
    for p in room.remote_participants.values():
        _joined(p)

    mic = Mic()
    track = rtc.LocalAudioTrack.create_audio_track("microphone", mic.source)
    await lp.publish_track(track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
    mic.start()

    async def send(topic: str, text: str) -> None:
        await lp.publish_data(text.encode(), reliable=True, topic=topic)
        print(f"  -> {topic}: {text[:80]!r}", flush=True)

    def onset_after(t: float) -> float | None:
        for o in world.speech_onsets:
            if o >= t:
                return o
        return None

    async def wait_for(pred, timeout: float, step: float = 0.05) -> bool:
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return True
            await asyncio.sleep(step)
        return pred()

    def state() -> str:
        return world.agent_states[-1][1] if world.agent_states else ""

    async def wait_quiet(timeout: float = 25.0) -> None:
        """Wait until the agent is listening and its audio has been silent for a moment."""
        await wait_for(
            lambda: state() == "listening" and not world.in_speech and time.time() - world.last_loud > 0.8,
            timeout,
        )

    def user_finals_after(t: float) -> list[str]:
        return [x[2] for x in world.transcripts if x[0] >= t and x[1] == "user" and x[3] and x[2].strip()]

    turns: list[Turn] = []

    async def speak_turn(name: str, expect_reply: bool = True) -> Turn:
        await wait_quiet()
        t_start = time.time()
        print(f"\n== user says: {UTTERANCES[name]!r}", flush=True)
        end = await mic.say(clips[name])
        turn = Turn(name, end)
        if expect_reply:
            await wait_for(lambda: onset_after(end) is not None, 15)
            turn.first_audio = onset_after(end)
            if turn.first_audio:
                print(f"  first agent audio {1000 * (turn.first_audio - end):.0f} ms after end of speech", flush=True)
            turns.append(turn)
        await wait_for(lambda: bool(user_finals_after(t_start)), 5)
        heard = " ".join(user_finals_after(t_start))
        sim = similarity(heard, UTTERANCES[name])
        checks.check(f"transcript '{name}'", sim >= 0.8, f"heard {heard!r} (similarity {sim:.2f})")
        return turn

    try:
        # 1. dispatch + config handshake + first message
        ok = await wait_for(lambda: agent_joined.is_set(), 20)
        if not checks.check("agent dispatched and joined", ok, world.agent_identity):
            print("no worker took the job (is the voice-agent worker registered and available?)")
            return 1
        await wait_for(lambda: world.config_requests > 0, 15)
        checks.check("happy.getConfig RPC called", world.config_requests == 1, f"{world.config_requests} call(s)")
        ok = await wait_for(lambda: bool(world.speech_onsets), 20)
        checks.check("first message spoken (agent audio has energy)", ok)
        await wait_for(
            lambda: any(x[1] == "agent" and "happy" in x[2].lower() for x in world.transcripts), 10
        )
        first = [x[2] for x in world.transcripts if x[1] == "agent"]
        checks.check(
            "first message text",
            any("happy here" in t.lower() for t in first),
            repr(first[:1]),
        )
        checks.check(
            "lk.agent.state published",
            {"listening", "speaking"} <= {s for _, s in world.agent_states},
            " -> ".join(s for _, s in world.agent_states),
        )

        # 2. spoken instruction -> sendMessageToSession
        n_calls = len(world.rpc_calls)
        await speak_turn("list_files")
        await wait_for(lambda: len(world.rpc_calls) > n_calls, 15)
        calls = [c for c in world.rpc_calls[n_calls:] if c[1] == "sendMessageToSession"]
        good = bool(calls) and calls[0][2].get("sessionId") == SESSION_ID and all(
            w in calls[0][2].get("message", "").lower() for w in ("list", "file")
        )
        checks.check("sendMessageToSession called with sensible args", good, json.dumps(calls[0][2]) if calls else "no call")

        # 3. silent context: no reply
        await wait_quiet()
        n_onsets = len(world.speech_onsets)
        t0 = time.time()
        await send(
            "happy.context",
            f"New messages in session: {SESSION_ID}\n\nClaude Code: \n<text>Listing the files in src now.</text>",
        )
        await asyncio.sleep(5)
        silent = len(world.speech_onsets) == n_onsets and not any(
            t >= t0 and s in ("thinking", "speaking") for t, s in world.agent_states
        )
        checks.check("happy.context produces no reply", silent)

        # 4. injected text turn: spoken reply
        await send(
            "happy.context",
            f"New messages in session: {SESSION_ID}\n\nClaude Code: \n<text>The src folder has 12 files: "
            "index.ts, server.ts, auth.ts, tokens.ts and 8 test files.</text>",
        )
        t_text = time.time()
        await send(
            "happy.text",
            f"Claude Code done working in session: {SESSION_ID}. The previous message(s) are the summary "
            "of the work done. Report this to the human immediately.",
        )
        ok = await wait_for(lambda: onset_after(t_text) is not None, 15)
        o = onset_after(t_text)
        checks.check(
            "happy.text produces a spoken reply",
            ok,
            f"first audio {1000 * (o - t_text):.0f} ms after the message" if o else "",
        )
        await wait_quiet()
        replies = [x[2] for x in world.transcripts if x[0] >= t_text and x[1] == "agent" and x[2].strip()]
        print(f"  agent reply: {replies[-1] if replies else ''!r}", flush=True)

        # 5. a question answered from context (latency sample)
        await speak_turn("about")

        # 6. pending permission in context, then "yes, allow it"
        await wait_quiet()
        await send(
            "happy.context",
            f"Claude Code is requesting permission to use Bash (session {SESSION_ID}):\n"
            f"<request_id>{REQUEST_ID}</request_id>\n<tool_name>Bash</tool_name>\n"
            '<tool_args>{"command":"ls -la src"}</tool_args>',
        )
        await asyncio.sleep(1.0)
        n_calls = len(world.rpc_calls)
        await speak_turn("allow")
        await wait_for(lambda: len(world.rpc_calls) > n_calls, 15)
        calls = [c for c in world.rpc_calls[n_calls:] if c[1] == "processPermissionRequest"]
        checks.check(
            "processPermissionRequest called with allow",
            bool(calls) and calls[0][2] == {"requestId": REQUEST_ID, "decision": "allow"},
            json.dumps(calls[0][2]) if calls else "no call",
        )

        # 7. one more latency sample
        await speak_turn("thanks")
        await wait_quiet()

        lat = [1000 * (t.first_audio - t.speech_end) for t in turns if t.first_audio]
        if lat:
            print(
                f"\nend of user speech -> first agent audio over {len(lat)} turns: "
                + ", ".join(f"{x:.0f}" for x in lat)
                + f" ms; p50 {statistics.median(lat):.0f} ms, max {max(lat):.0f} ms",
                flush=True,
            )
        checks.check("every spoken turn got an audible reply", len(lat) == len(turns), f"{len(lat)}/{len(turns)}")

        print("\nagent transcript:")
        for t, who, text, final in world.transcripts:
            if final and text.strip():
                print(f"  {who:5} {text}")
    finally:
        await room.disconnect()

    failed = [r for r in checks.results if not r[1]]
    print(f"\n{len(checks.results) - len(failed)}/{len(checks.results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
