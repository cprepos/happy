"""End-to-end test: a headless LiveKit client that behaves like the ElevenLabs Swift SDK 3.4.0.

It mints its own token with agent dispatch to `happy-voice-el`, connects, waits up to 3 s for
the agent to join (the SDK's agentReadyTimeout) and then sends conversation_initiation_client_data
the way the app does: its CallPrompt.system as the prompt override, the language, and the call's
context in dynamic_variables.initialConversationContext. From then on it only speaks the SDK's
data-channel protocol: pongs for pings, client_tool_result for the four client tools (answered
from canned app results), contextual_update and user_message. Every event the agent sends is
checked against the SDK's parser rules (EventParser.swift, kept in happy_voice.elevenlabs_protocol);
an unknown type counts as an error here, though the SDK only logs it.

    python tests/e2e_elevenlabs_sdk.py --livekit ws://192.168.2.56:7880 [--scenario call|compaction]

With --token-url (the ElevenLabs-compatible server, packages/elevenlabs-server) it does what the
SDK does instead of minting: GET <token-url>?agent_id=…&source=swift_sdk&version=3.4.0 with no
auth, and connects LiveKit through the same server (the token URL without
/v1/convai/conversation/token, as ws/wss) unless --livekit is given:

    python tests/e2e_elevenlabs_sdk.py \
        --token-url https://happy.girthbass.duckdns.org/elevenlabs/v1/convai/conversation/token

`call` (the default): a greeting-only turn (with an echo check), the four tool round trips, a
barge-in, plain latency turns and a goodbye that ends with end_call.
`compaction`: needs the worker running with a low trigger (VOICE_COMPACT_TRIGGER=12000,
VOICE_COMPACT_SUMMARY_TOKENS=1500); plants a fact early, loads the history past the trigger,
waits for the swap (seen through --agent-log-cmd when given) and asks about the fact.

Exit code 0 when every check passes.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import aiohttp
import jwt as pyjwt
import numpy as np
from livekit import api, rtc

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

from e2e_fake_app import SPEECH_RMS, Checks, Mic, load_env, norm_words, similarity, synthesize  # noqa: E402
from happy_voice import elevenlabs_protocol as el  # noqa: E402

DEFAULT_ENV = HERE.parents[2] / "selfhost" / ".env.voice"
AGENT_READY_TIMEOUT = 3.0  # ConversationStartupConfiguration.agentReadyTimeout default
SDK_VERSION = "3.4.0"

# CallPrompt.system from packages/happy-ios/Sources/HappyCore/Call/CallTools.swift (origin/main)
CALL_PROMPT = """You are Happy, the voice side of the person's coding agents. The agents do the deep work: they read the code, run things and think problems through. You don't. You talk with the person and relay, like a colleague passing on what a more experienced colleague found: the point first, in plain words. Be brief: a sentence or two unless asked for more. A summary is two or three sentences: where things stand, then what matters ("Still writing the 2.4 notes. It flagged a sync change that breaks old desktops."). More only when asked. Respect the person's time. Never explain why you did or didn't do something; do it or don't. Don't announce a tool call; make it.

Context: {{initialConversationContext}} is given once at the start: the time, what you and the person said in recent calls, the conversation on screen with its last turns, the conversations in the app with their refs, and where navigate can go. During the call, updates say what changed: conversations added, renamed, moved or removed; what's on screen; an agent's reply; an agent's error; silence over (someone spoke after a silence warning: the call goes on, don't bring the warning up again). You hear replies only from the four conversations most recently visited or messaged. Updates need no answer; use them when they matter to what you're saying. Name conversations to tools by ref (s3), never by title. "New Task" is work not yet named. On a team, readConversation says who wrote each message; "the person" is whoever is on this call.

Tools:
- listConversations: find conversations by title, ones started during the call too.
- readConversation: read a conversation before you summarise it. from and backTo read further back; to hear a cut message whole, read that turn alone with a higher words. If it says it is refreshing, answer from it now; anything newer comes as an [app] message.
- message: send to a conversation (to: its ref, or leave it out for the one on screen), or start new work (to: new-task or new-bot, optionally with :Name).
- navigate: change the screen, only when asked. to is happy://home, happy://back or happy://conversation/<ref>. Pass the latest focusRevision you've seen; if refused because the screen changed, retry with the newer one.

Sending:
- Assume the person is thinking aloud. While they are, answer in a few words at most ("Mm-hm.", "Got it."): don't weigh in, don't analyse, don't offer to send. When they ask you to send, or to have a conversation do something ("send it", "tell the cache task to ...", "have the release task ..."), send at once, without checking back. Ask "Send it?" only when you truly can't tell.
- Send their words verbatim, as they said them, hedges included: you don't have the context to summarise them, and the agent does. Don't rephrase, tidy, shorten or add. Leave out only the instruction to send itself. If they built it up over several turns, send all of it.
- Send to the conversation they named, or the one on screen if they named none. If neither is clear, ask which.
- Conversations are bots, tasks, and subtasks under a bot or task. Message any that already exists by its ref.
- New work:
  - New subtask: you can't start one yourself. Send to its parent bot or task, keeping the ask for a subtask in the words; the parent starts it.
  - New top-level task: to is new-task.
  - New bot: to is new-bot, only when the person asks for a bot by name. Never suggest one: ongoing work is still a task unless they say bot.
- Pass model or effort only when asked, using names the context or readConversation lists. If one is refused, say which ones it takes.
- After a send, say "Sent." with at most a few words on what the agent will do ("Sent. It'll dig into the cache race."). Never repeat the message back. If it failed, say so in a few words with what to do ("Didn't go through; answer it in the app."). If uncertain, say "Not sure that went through." and nothing more. Never send it again on your own.

Speaking:
- Use skip_turn freely: when nothing needs saying (an update, news that no longer matters), call it and stay silent rather than say something empty.
- Only say something happened if a tool said so.
- Never read out code, paths, logs, commit hashes or IDs. Say what they mean.
- Say times as "ago"; give the exact time only if asked.
- You can't approve permissions or answer an agent's questions. When one needs input, tell the person to answer it in the app.
- Recent calls are there to carry on from. Never repeat a send or a navigate because it appears there.

A message starting with [app] is from the app, not the person. Don't read it out; answer at once, briefly, in your own words:
- An agent's news on a conversation you read: say what's new, newest first, unless it no longer matters.
- Silence: say the call ends soon because it's quiet, and you can pick up next time. Don't end the call yourself.
- Call ending: say it ends soon and why. If a restart is offered, offer it, and navigate to happy://call/restart only after a yes.
"""

CONVERSATIONS = [
    {"ref": "s1", "title": "Fix the cache race", "kind": "task", "status": "working", "lastActivity": "2 minutes ago"},
    {"ref": "s2", "title": "Release 2.4 notes", "kind": "task", "status": "idle", "lastActivity": "1 hour ago"},
    {"ref": "s3", "title": "Docs bot", "kind": "bot", "status": "idle", "lastActivity": "yesterday"},
]

INITIAL_CONTEXT = json.dumps(
    {
        "now": "Friday 27 November 2026, 14:05",
        "recentCalls": [],
        "screen": {"ref": "s1", "title": "Fix the cache race", "focusRevision": 7},
        "lastTurns": [
            {"by": "the person", "text": "Find out why the cache sometimes serves stale entries."},
            {"by": "agent", "text": "Looking into it; I suspect two refreshes racing."},
        ],
        "conversations": CONVERSATIONS,
        "navigate": ["happy://home", "happy://back", "happy://conversation/<ref>"],
    },
    sort_keys=True,
)

S1_TURNS = {
    "ref": "s1",
    "title": "Fix the cache race",
    "turns": [
        {"by": "the person", "text": "Find out why the cache sometimes serves stale entries."},
        {
            "by": "agent",
            "text": "Found it: two writers refresh the same cache entry at once and the slower one wins "
            "with old data. I put a lock around the refresh. All 212 tests pass.",
        },
    ],
}

S2_LONG = {
    "ref": "s2",
    "title": "Release 2.4 notes",
    "turns": [
        {"by": "the person", "text": "Write the 2.4 release notes, every change, with why it matters."},
        {
            "by": "agent",
            "text": " ".join(
                f"Change {i}: {what}, which matters because {why}."
                for i, (what, why) in enumerate(
                    [
                        ("sync now batches writes", "phones on bad networks stop timing out"),
                        ("the sidebar remembers its order", "people lost their place after a restart"),
                        ("voice calls reconnect on their own", "a dropped wifi used to end the call"),
                        ("search covers archived chats", "old answers were impossible to find"),
                        ("the desktop app checks its version", "old desktops broke on the new sync"),
                        ("attachments upload in the background", "big files froze the composer"),
                        ("teams see who wrote each message", "shared tasks were confusing"),
                        ("dark mode follows the system", "it ignored the phone setting"),
                    ],
                    1,
                )
            ),
        },
    ],
}

UTTERANCES = {
    "greeting": "Hello, how's it going?",
    "list": "Which conversations do I have open?",
    "read": "What's the latest on the cache race?",
    "message": "Tell the cache task to add a regression test for the race.",
    "navigate": "Take me to the home screen.",
    "long": "Go through the release notes conversation for me, every change in it, one by one.",
    "stop": "Okay, stop there.",
    "plain1": "How long ago did the release notes task last do anything?",
    "plain2": "Is the cache task still working?",
    "plain3": "What day is it today?",
    "plain4": "Remind me what I asked the cache task to find out.",
    "bye": "That's all for now, thanks. Bye!",
    # compaction scenario
    "c_plant": "Read me the latest from the release notes conversation.",
    "c_q1": "What is the cache task doing right now?",
    "c_q2": "Anything new from the docs bot?",
    "c_q3": "And the release notes task?",
    "c_recall": "Remind me, why was the release blocked?",
    "c_after": "What is the cache task doing right now?",
}

PLANTED = (
    "Release is blocked: build 4471 failed to sign because the signing certificate expired last night; "
    "someone with the developer account must renew it before the release can ship."
)
FILLER_TOPICS = [
    "reread the cache module and traced the refresh path through the scheduler",
    "checked the lock ordering against the eviction worker and the metrics hook",
    "ran the soak test for ten minutes with four writers and found no stale reads",
    "compared the old and new refresh timings across three regions",
    "looked at the docs bot's draft of the API page and fixed two broken links",
    "went over the onboarding guide and shortened the install section",
]


def filler_update(n: int, words: int = 380) -> str:
    """A contextual update the app could send: an agent's long reply in one of the conversations."""
    ref = "s1" if n % 2 == 0 else "s3"
    body = []
    i = 0
    while sum(len(b.split()) for b in body) < words:
        body.append(f"Step {n}.{i}: {FILLER_TOPICS[(n + i) % len(FILLER_TOPICS)]}.")
        i += 1
    return json.dumps({"event": "assistant_text", "ref": ref, "text": " ".join(body)})


@dataclass
class Event:
    t: float
    type: str
    body: dict[str, Any]


@dataclass
class World:
    events: list[Event] = field(default_factory=list)
    protocol_errors: list[str] = field(default_factory=list)
    pings: int = 0
    speech_onsets: list[float] = field(default_factory=list)
    last_loud: float = 0.0
    in_speech: bool = False
    agent_identity: str = ""
    tool_log: list[dict[str, Any]] = field(default_factory=list)
    ended: float | None = None

    def of(self, kind: str, after: float = 0.0) -> list[Event]:
        return [e for e in self.events if e.type == kind and e.t >= after]

    def onset_after(self, t: float) -> float | None:
        return next((o for o in self.speech_onsets if o >= t), None)


FOCUS = {"revision": 7}


def tool_result(name: str, params: dict[str, Any]) -> tuple[str, bool]:
    """What the app's CallTools would answer, canned."""
    if name == "listConversations":
        q = str(params.get("query") or "").lower()
        rows = [c for c in CONVERSATIONS if q in c["title"].lower()]
        return json.dumps({"conversations": rows, "nextCursor": None}, sort_keys=True), False
    if name == "readConversation":
        ref = str(params.get("ref") or "")
        if ref == "s1":
            return json.dumps(S1_TURNS, sort_keys=True), False
        if ref == "s2":
            return json.dumps(S2_LONG, sort_keys=True), False
        if ref == "s3":
            return json.dumps({"ref": "s3", "title": "Docs bot", "turns": []}, sort_keys=True), False
        return json.dumps({"ok": False, "reason": f"no conversation {ref}"}, sort_keys=True), True
    if name == "message":
        return json.dumps({"ok": True, "sentTo": params.get("to") or "s1"}, sort_keys=True), False
    if name == "navigate":
        if params.get("focusRevision") != FOCUS["revision"]:
            return json.dumps(
                {"ok": False, "reason": "the screen changed", "focusRevision": FOCUS["revision"]}, sort_keys=True
            ), True
        FOCUS["revision"] += 1
        return json.dumps({"ok": True, "screen": params.get("to"), "focusRevision": FOCUS["revision"]}, sort_keys=True), False
    return json.dumps({"ok": False, "reason": f"unknown tool {name}"}, sort_keys=True), True


def livekit_url_for(token_url: str) -> str:
    """apiEndpoint -> websocketUrl: the server root, as ws(s)."""
    base = token_url.split("?", 1)[0].removesuffix("/").removesuffix("/v1/convai/conversation/token")
    return "wss://" + base[len("https://"):] if base.startswith("https://") else "ws://" + base.removeprefix("http://")


async def fetch_sdk_token(token_url: str, agent_id: str) -> str:
    """The SDK's one HTTP call (TokenService.fetchConversationToken): no auth, 200 + non-empty token."""
    params = {"agent_id": agent_id, "source": "swift_sdk", "version": SDK_VERSION}
    async with aiohttp.ClientSession() as http:
        async with http.get(token_url, params=params, timeout=aiohttp.ClientTimeout(total=10)) as r:
            if r.status != 200:
                raise SystemExit(f"token call failed: HTTP {r.status} {(await r.text())[:200]}")
            body = await r.json(content_type=None)
    token = body.get("token") if isinstance(body, dict) else None
    if not isinstance(token, str) or not token:
        raise SystemExit("token call returned no token")
    return token


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default=str(DEFAULT_ENV))
    ap.add_argument("--livekit", default=None)
    ap.add_argument("--tts", default=None)
    ap.add_argument("--voice", default="am_michael")
    ap.add_argument("--agent-name", default="happy-voice-el")
    ap.add_argument("--scenario", choices=["call", "compaction"], default="call")
    # e.g. "ssh prep-air tail -n 4000 happy/selfhost/mac-voice/logs/agent-el.log": read to see the swap
    ap.add_argument("--agent-log-cmd", default=os.environ.get("EL_AGENT_LOG_CMD"))
    ap.add_argument("--plant", default=PLANTED, help=argparse.SUPPRESS)
    ap.add_argument("--token-url", default=None, help="fetch the token the SDK way from this apiEndpoint")
    ap.add_argument("--agent-id", default="agent_happy_voice_el", help="agent_id sent with --token-url")
    args = ap.parse_args()

    env = load_env(Path(args.env))
    if args.token_url and not args.livekit:
        args.livekit = livekit_url_for(args.token_url)
    args.livekit = args.livekit or env.get("LIVEKIT_URL") or os.environ.get("LIVEKIT_URL") or "ws://127.0.0.1:7880"
    args.tts = args.tts or env.get("TTS_URL") or os.environ.get("TTS_URL") or "http://127.0.0.1:8880/v1"
    key, secret = env["LIVEKIT_API_KEY"], env["LIVEKIT_API_SECRET"]
    room_name = f"voice-el-e2e-{uuid.uuid4().hex[:8]}"
    identity = "user-el-e2e"
    checks = Checks()
    world = World()
    wanted = [k for k in UTTERANCES if (k.startswith("c_") == (args.scenario == "compaction"))]

    async with aiohttp.ClientSession() as http:
        print(f"synthesizing {len(wanted)} utterances with Kokoro ({args.voice})", flush=True)
        clips = {k: await synthesize(http, args.tts, UTTERANCES[k], args.voice) for k in wanted}

    if args.token_url:
        t_tok = time.time()
        token = await fetch_sdk_token(args.token_url, args.agent_id)
        claims = pyjwt.decode(token, options={"verify_signature": False})
        room_name = claims.get("video", {}).get("room", "?")
        dispatched = [a.get("agentName") for a in claims.get("roomConfig", {}).get("agents", [])]
        print(f"token from {args.token_url} in {(time.time() - t_tok) * 1000:.0f} ms: room {room_name}, "
              f"identity {claims.get('sub')}, agents {dispatched}, ttl {claims['exp'] - claims['nbf']}s; "
              f"LiveKit via {args.livekit}", flush=True)
        checks.check("token server dispatches the agent", dispatched == [args.agent_name], f"{dispatched}")
    else:
        token = None
    token = token or (
        api.AccessToken(key, secret)
        .with_identity(identity)
        .with_name("E2E ElevenLabs SDK")
        .with_grants(
            api.VideoGrants(room_join=True, room=room_name, can_publish=True, can_subscribe=True, can_publish_data=True)
        )
        .with_room_config(api.RoomConfiguration(agents=[api.RoomAgentDispatch(agent_name=args.agent_name)]))
        .to_jwt()
    )

    room = rtc.Room()
    lp: rtc.LocalParticipant | None = None
    t0 = time.time()

    async def send(event: dict[str, Any]) -> None:
        assert lp is not None
        # the SDK publishes reliably with no topic
        await lp.publish_data(json.dumps(event).encode(), reliable=True)
        if event["type"] != "pong":
            print(f"  -> {event['type']} {json.dumps(event)[:120]}", flush=True)

    async def answer_tool(ev: Event) -> None:
        body = ev.body
        name, params, call_id = body.get("tool_name"), body.get("parameters") or {}, body.get("tool_call_id")
        result, is_error = tool_result(name, params)
        await asyncio.sleep(0.02)  # the app's own work
        await send({"type": "client_tool_result", "tool_call_id": call_id, "result": result, "is_error": is_error})
        world.tool_log.append(
            {"name": name, "params": params, "t_call": ev.t, "t_result": time.time(), "is_error": is_error}
        )

    def on_data(packet: rtc.DataPacket) -> None:
        now = time.time()
        try:
            data = json.loads(packet.data)
        except ValueError:
            world.protocol_errors.append(f"not JSON: {packet.data[:80]!r}")
            return
        kind = data.get("type") if isinstance(data, dict) else None
        if kind not in el.KNOWN_AGENT_EVENTS:
            world.protocol_errors.append(f"unknown event type {kind!r}")
            return
        errors = el.validate_agent_event(data)
        if errors:
            world.protocol_errors.append(f"{kind}: {'; '.join(errors)}")
        if packet.topic:
            world.protocol_errors.append(f"{kind} sent on topic {packet.topic!r} (the SDK reads any topic)")
        envelope = el._AGENT_EVENT_RULES.get(kind, ("", {}))[0]
        body = data.get(envelope, {}) if envelope else data
        ev = Event(now, kind, body if isinstance(body, dict) else {})
        world.events.append(ev)
        if kind == "ping":
            world.pings += 1
            asyncio.create_task(send({"type": "pong", "event_id": ev.body.get("event_id")}))
        elif kind == "client_tool_call":
            print(f"  <- client_tool_call {ev.body.get('tool_name')} {json.dumps(ev.body.get('parameters'))}", flush=True)
            asyncio.create_task(answer_tool(ev))
        elif kind == "agent_tool_response" and ev.body.get("tool_name") == el.END_CALL_TOOL:
            print("  <- agent_tool_response end_call: the SDK ends the call", flush=True)
            world.ended = now
        elif kind in ("agent_response", "user_transcript", "interruption", "conversation_initiation_metadata"):
            text = ev.body.get("agent_response") or ev.body.get("user_transcript") or ""
            print(f"  <- {kind} {text!r}" if text else f"  <- {kind} {json.dumps(ev.body)}", flush=True)

    room.on("data_received", on_data)

    agent_joined = asyncio.Event()

    @room.on("participant_connected")
    def _joined(p: rtc.RemoteParticipant) -> None:
        if p.identity.startswith("agent"):
            world.agent_identity = p.identity
            agent_joined.set()

    async def consume_audio(track: rtc.Track) -> None:
        async for ev in rtc.AudioStream(track, sample_rate=24000, num_channels=1):
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
            asyncio.create_task(consume_audio(track))

    async def wait_for(pred, timeout: float, step: float = 0.05) -> bool:
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return True
            await asyncio.sleep(step)
        return pred()

    def busy_events(after: float) -> list[Event]:
        return [e for e in world.events if e.t >= after and e.type not in ("ping", "vad_score")]

    async def wait_quiet(timeout: float = 30.0) -> None:
        """Until the agent's audio has been silent a while and it has sent nothing for a moment."""
        await wait_for(
            lambda: not world.in_speech
            and time.time() - world.last_loud > 1.5
            and not busy_events(time.time() - 1.2)
            and all(t.get("t_result") for t in world.tool_log),
            timeout,
        )

    def heard_after(t: float) -> str:
        return " ".join(e.body.get("user_transcript", "") for e in world.of("user_transcript", t))

    def said_after(t: float) -> str:
        return " ".join(e.body.get("agent_response", "") for e in world.of("agent_response", t))

    latencies: dict[str, float] = {}
    tool_turns: set[str] = set()

    async def speak_turn(name: str, expect_reply: bool = True, quiet_first: bool = True) -> tuple[float, float | None]:
        heard, sim, end, first = "", 0.0, 0.0, None
        for attempt in (1, 2):
            if quiet_first:
                await wait_quiet()
            t_start = time.time()
            print(f"\n== user says: {UTTERANCES[name]!r}" + (" (retry)" if attempt == 2 else ""), flush=True)
            end = await mic.say(clips[name])
            if expect_reply:
                await wait_for(lambda: world.onset_after(end) is not None, 20)
                first = world.onset_after(end)
                if first and attempt == 1:
                    latencies[name] = 1000 * (first - end)
                    if any(end - 1 <= x["t_call"] <= first for x in world.tool_log):
                        tool_turns.add(name)
                    print(f"  first agent audio {latencies[name]:.0f} ms after end of speech", flush=True)
            await wait_for(lambda: bool(heard_after(t_start)), 6)
            heard = heard_after(t_start)
            sim = similarity(heard, UTTERANCES[name])
            if sim >= 0.75 or not quiet_first:
                break
            print(f"  transcript below threshold (similarity {sim:.2f})", flush=True)
        checks.check(f"user_transcript '{name}'", sim >= 0.75, f"heard {heard!r} (similarity {sim:.2f})")
        return end, first

    async def agent_log() -> str:
        if not args.agent_log_cmd:
            return ""
        proc = await asyncio.create_subprocess_shell(
            args.agent_log_cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
        )
        out, _ = await proc.communicate()
        return out.decode(errors="replace")

    def tools_after(t: float, name: str) -> list[dict[str, Any]]:
        return [x for x in world.tool_log if x["t_call"] >= t and x["name"] == name]

    try:
        # --- startup, as WebRTCConnectionManager.connect does it ------------------------------
        await room.connect(args.livekit, token)
        lp = room.local_participant
        mic = Mic()
        track = rtc.LocalAudioTrack.create_audio_track("microphone", mic.source)
        await lp.publish_track(track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        mic.start()
        t_room = time.time()
        print(f"joined {room_name} in {t_room - t0:.2f}s", flush=True)
        for p in room.remote_participants.values():
            _joined(p)
        ok = await wait_for(agent_joined.is_set, AGENT_READY_TIMEOUT)
        if not checks.check(
            f"agent joined within the SDK's {AGENT_READY_TIMEOUT:.0f}s",
            ok,
            f"{world.agent_identity} after {time.time() - t_room:.2f}s" if ok else "agentTimeout",
        ):
            return 1
        await send(
            {
                "type": "conversation_initiation_client_data",
                "conversation_config_override": {"agent": {"prompt": {"prompt": CALL_PROMPT}, "language": "en"}},
                "dynamic_variables": {"initialConversationContext": INITIAL_CONTEXT},
                "source_info": {"source": "swift_sdk", "version": SDK_VERSION},
                "user_id": "user-el-e2e",
            }
        )
        t_init = time.time()
        ok = await wait_for(lambda: bool(world.of("conversation_initiation_metadata")), 5)
        checks.check(
            "conversation_initiation_metadata received",
            ok,
            f"{1000 * (world.of('conversation_initiation_metadata')[0].t - t_init):.0f} ms after init" if ok else "",
        )
        if ok:
            meta = world.of("conversation_initiation_metadata")[0].body
            checks.check(
                "audio formats are pcm_<rate>",
                str(meta.get("agent_output_audio_format", "")).startswith("pcm_"),
                json.dumps(meta),
            )
        await asyncio.sleep(1.0)  # no first message: the app sends none

        if args.scenario == "call":
            await run_call(world, checks, speak_turn, wait_quiet, wait_for, send, said_after, tools_after, latencies, mic, clips)
        else:
            await run_compaction(
                world, checks, speak_turn, wait_quiet, wait_for, send, said_after, tools_after, latencies, agent_log
            )

        checks.check("pings answered", world.pings > 0, f"{world.pings} ping(s)")
        checks.check(
            "every event passes the SDK parser rules",
            not world.protocol_errors,
            "; ".join(world.protocol_errors[:5]) or f"{len(world.events)} events",
        )
        rtts = [1000 * (x["t_result"] - x["t_call"]) for x in world.tool_log]
        if world.tool_log:
            print(
                "\ntool round trips (client_tool_call in -> result out): "
                + ", ".join(f"{x['name']} {r:.0f} ms" for x, r in zip(world.tool_log, rtts)),
                flush=True,
            )
            post = []
            for x in world.tool_log:
                o = world.onset_after(x["t_result"])
                if o is not None and o - x["t_result"] < 15:
                    post.append(f"{x['name']} {1000 * (o - x['t_result']):.0f} ms")
            print("tool result -> first agent audio: " + ", ".join(post), flush=True)
        if latencies:
            lat = list(latencies.values())
            print(
                "end of user speech -> first agent audio: "
                + ", ".join(f"{k}{'*' if k in tool_turns else ''} {v:.0f}" for k, v in latencies.items())
                + f" ms; p50 {statistics.median(lat):.0f} ms, max {max(lat):.0f} ms (* = a tool ran first)",
                flush=True,
            )
            plain = [v for k, v in latencies.items() if k not in tool_turns]
            if plain:
                print(
                    f"  turns with no tool call: p50 {statistics.median(plain):.0f} ms, max {max(plain):.0f} ms "
                    f"over {len(plain)}",
                    flush=True,
                )
        print("\nconversation:")
        for e in world.events:
            if e.type in ("user_transcript", "agent_response"):
                who = "user " if e.type == "user_transcript" else "agent"
                print(f"  {who} {e.body.get(e.type, '')}")
    finally:
        await room.disconnect()

    failed = [r for r in checks.results if not r[1]]
    print(f"\n{len(checks.results) - len(failed)}/{len(checks.results)} checks passed")
    return 1 if failed else 0


async def run_call(world, checks, speak_turn, wait_quiet, wait_for, send, said_after, tools_after, latencies, mic, clips):
    # 1. a greeting-only turn: the reply must not echo it
    end, first = await speak_turn("greeting")
    await wait_quiet()
    reply = said_after(end)
    echo = similarity(reply, UTTERANCES["greeting"]) >= 0.6 or " ".join(norm_words(reply)).startswith(
        "hello how is it going"
    )
    checks.check("greeting-only turn answered", first is not None, repr(reply))
    checks.check("greeting reply does not echo the greeting", not echo, repr(reply))

    # 2. the four client tools
    plan = [
        ("list", "listConversations", lambda p: True),
        ("read", "readConversation", lambda p: p.get("ref") == "s1"),
        ("message", "message", lambda p: "regression test" in str(p.get("text", "")).lower()),
        ("navigate", "navigate", lambda p: p.get("to") == "happy://home" and p.get("focusRevision") == 7),
    ]
    for utterance, tool, good in plan:
        end, _ = await speak_turn(utterance)
        await wait_for(lambda: bool(tools_after(end - 1, tool)), 20)
        await wait_quiet()
        calls = tools_after(end - 1, tool)
        checks.check(
            f"{tool} round trip",
            bool(calls) and good(calls[0]["params"]),
            (json.dumps(calls[0]["params"]) + f"; then said {said_after(calls[0]['t_result'])!r}") if calls else
            f"no call; said {said_after(end)!r}",
        )

    # 3. barge-in: interrupt a long answer by speaking
    end, first = await speak_turn("long")
    interrupted = False
    for _ in range(2):
        # let the answer get going (after any tool round trip), then talk over it
        await wait_for(lambda: world.in_speech and time.time() - (world.onset_after(end) or time.time()) > 1.5, 25)
        if not world.in_speech:
            break
        t_stop = time.time()
        stop_end = await mic.say(clips["stop"])
        ok = await wait_for(lambda: bool(world.of("interruption", t_stop)), 6)
        quiet = await wait_for(lambda: not world.in_speech, 3)
        if ok:
            ev = world.of("interruption", t_stop)[0]
            checks.check(
                "barge-in sends interruption",
                True,
                f"event_id {ev.body.get('event_id')}, {1000 * (ev.t - t_stop):.0f} ms after the user started; "
                f"agent audio {'stopped' if quiet else 'still going'}",
            )
            checks.check("agent audio stops on barge-in", quiet)
            interrupted = True
            del stop_end
            break
        await wait_quiet()
        end, first = await speak_turn("long")
    if not interrupted:
        checks.check("barge-in sends interruption", False, "no interruption event (or the answer was too short)")

    # 4. plain latency turns
    for name in ("plain1", "plain2", "plain3", "plain4"):
        await speak_turn(name)

    # 5. goodbye: the agent says goodbye, then end_call ends the call the way the SDK does it
    end, _ = await speak_turn("bye")
    ok = await wait_for(lambda: world.ended is not None, 20)
    goodbye = said_after(end)
    checks.check(
        "goodbye ends with agent_tool_response end_call",
        ok,
        f"{1000 * (world.ended - end):.0f} ms after the goodbye; said {goodbye!r}" if ok else f"said {goodbye!r}",
    )
    if ok:
        # the SDK ends the call on end_call, so the goodbye must have played by then
        await asyncio.sleep(1.0)
        checks.check(
            "end_call arrives after the goodbye was spoken",
            bool(goodbye) and world.last_loud <= world.ended,
            f"agent audio last heard {1000 * (world.ended - world.last_loud):.0f} ms before end_call",
        )


async def run_compaction(world, checks, speak_turn, wait_quiet, wait_for, send, said_after, tools_after, latencies, agent_log):
    before = (await agent_log()).count("compaction: prompt ")
    turns: list[tuple[str, float, float | None]] = []

    # 1. the planted fact arrives as a tool result early in the call
    global S2_LONG
    S2_LONG = {"ref": "s2", "title": "Release 2.4 notes", "turns": [{"by": "agent", "text": PLANTED}]}
    end, first = await speak_turn("c_plant")
    turns.append(("c_plant", end, first))
    await wait_for(lambda: bool(tools_after(end - 1, "readConversation")), 20)
    await wait_quiet()
    checks.check(
        "planted fact read through readConversation",
        bool(tools_after(end - 1, "readConversation")),
        repr(said_after(end)),
    )

    # 2. load the history well past the trigger with contextual updates (agents' long replies)
    n_updates = 26
    for n in range(n_updates):
        await send({"type": "contextual_update", "text": filler_update(n)})
        await asyncio.sleep(0.15)
    await asyncio.sleep(2.0)

    # 3. turns that run requests over the trigger; the swap happens in a quiet moment after one
    swapped_at = None
    for name in ("c_q1", "c_q2", "c_q3"):
        end, first = await speak_turn(name)
        turns.append((name, end, first))
        await wait_quiet()
        if args_log_has(await agent_log(), before):
            swapped_at = time.time()
            break
    if swapped_at is None:
        # the swap waits for a quiet window after the summary is written
        for _ in range(30):
            await asyncio.sleep(2)
            if args_log_has(await agent_log(), before):
                swapped_at = time.time()
                break
    log = await agent_log()
    lines = [l for l in log.splitlines() if "compaction: prompt " in l]
    checks.check(
        "compaction summarized and swapped",
        len(lines) > before,
        lines[-1].split("compaction: ", 1)[-1] if len(lines) > before else "no swap line in the agent log"
        + ("" if log else " (no --agent-log-cmd)"),
    )

    # 4. after the swap: the fact only the summary holds, and an ordinary turn
    end, first = await speak_turn("c_recall")
    turns.append(("c_recall", end, first))
    await wait_quiet()
    recall = said_after(end).lower()
    checks.check(
        "a reply after the swap still knows the summarized fact",
        any(w in recall for w in ("certificate", "sign", "4471")),
        repr(said_after(end)),
    )
    end, first = await speak_turn("c_after")
    turns.append(("c_after", end, first))
    await wait_quiet()
    checks.check("a plain turn after the swap is answered", first is not None, repr(said_after(end)))

    # 5. no turn dropped: every user turn was transcribed and answered, in order
    answered = [name for name, end, first in turns if first is not None]
    checks.check("every turn answered across the swap", len(answered) == len(turns), f"{len(answered)}/{len(turns)}")


def args_log_has(log: str, before: int) -> bool:
    return log.count("compaction: prompt ") > before


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
