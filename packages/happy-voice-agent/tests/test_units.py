"""Unit tests for the pure helpers (no services needed).

    python -m pytest tests/test_units.py      or      python tests/test_units.py
"""

from __future__ import annotations

import asyncio
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from livekit.agents import llm  # noqa: E402

from happy_voice.assistant import (  # noqa: E402
    _SCRIPTED_REPLY_RE,
    TOPIC_INTERRUPTED,
    VoiceConfig,
    announce_interruptions,
)
from happy_voice.config import Settings  # noqa: E402
from happy_voice.names import persona_for, voice_name  # noqa: E402
from happy_voice.warmup import PrefixWarmer  # noqa: E402
from happy_voice.context import fold_system_messages, focused_session_from  # noqa: E402
from happy_voice import voices  # noqa: E402
from happy_voice.voices import (  # noqa: E402
    _voice_names,
    clamp_speed,
    parse_voice,
    resolve_tts,
    validate_voice,
)
from happy_voice.prompt import (  # noqa: E402
    BASE_PROMPT,
    CONTEXT_PREFIX,
    INTERRUPTED_MARKER,
    PERMISSION_SCHEMA,
    SEND_MESSAGE_SCHEMA,
    SKIP_TURN_SCHEMA,
    build_instructions,
)


def test_fold_moves_late_system_messages_to_user_role() -> None:
    ctx = llm.ChatContext.empty()
    ctx.add_message(role="system", content="instructions")
    ctx.add_message(role="system", content="initial context")
    ctx.add_message(role="assistant", content="Hi")
    ctx.add_message(role="system", content="Session became focused: abc")
    ctx.add_message(role="user", content="hello")
    out = [m for m in fold_system_messages(ctx).items if isinstance(m, llm.ChatMessage)]
    assert [m.role for m in out] == ["system", "assistant", "user", "user"]
    assert out[0].text_content == "instructions\n\ninitial context"
    assert out[2].text_content == CONTEXT_PREFIX + "Session became focused: abc"
    # input untouched
    assert ctx.items[3].role == "system"


def _clipped_history() -> llm.ChatContext:
    ctx = llm.ChatContext.empty()
    ctx.add_message(role="system", content="instructions")
    ctx.add_message(role="user", content="how did the loss go")
    ctx.add_message(role="assistant", content="It dropped from about 33", interrupted=True, id="clipped")
    ctx.add_message(role="user", content="and now")
    ctx.add_message(role="assistant", content="It is at 12 now.", id="whole")
    ctx.add_message(role="assistant", content="", interrupted=True, id="silent")
    return ctx


def test_fold_marks_interrupted_replies_on_the_request_only() -> None:
    ctx = _clipped_history()
    out = {m.id: m for m in fold_system_messages(ctx).items if isinstance(m, llm.ChatMessage)}
    assert out["clipped"].text_content == "It dropped from about 33" + INTERRUPTED_MARKER
    assert out["whole"].text_content == "It is at 12 now."
    # nothing was played, so there is nothing to mark
    assert out["silent"].text_content == ""
    # the stored history is untouched
    stored = {m.id: m for m in ctx.items}
    assert stored["clipped"].text_content == "It dropped from about 33"
    assert out["clipped"] is not stored["clipped"] and out["whole"] is stored["whole"]
    # folding a folded request does not mark twice
    again = {m.id: m for m in fold_system_messages(fold_system_messages(ctx)).items}
    assert again["clipped"].text_content == "It dropped from about 33" + INTERRUPTED_MARKER


def test_the_prompt_explains_the_interrupted_marker() -> None:
    assert INTERRUPTED_MARKER.strip() in BASE_PROMPT


def test_summary_and_warm_requests_carry_the_marker_and_the_swap_keeps_raw_items() -> None:
    from happy_voice.compaction import (
        Split,
        compacted_items,
        summary_message,
        summary_request,
        warm_request,
    )

    ctx = _clipped_history()
    items = list(ctx.items)
    split = Split(prefix=items[:1], head=items[1:3], tail=items[3:], head_tokens=0, tail_tokens=0)
    summary = {m.id: m for m in summary_request(split).items}
    assert summary["clipped"].text_content.endswith(INTERRUPTED_MARKER)
    warm = {m.id: m for m in warm_request(items).items}
    assert warm["clipped"].text_content.endswith(INTERRUPTED_MARKER)
    # a swap rebuilds the history from the raw items: a clipped reply in the kept tail stays
    # the stored, unmarked message
    swapped = compacted_items(items, {items[1].id}, summary_message("so far", 1))
    kept = {m.id: m for m in swapped}
    assert kept["clipped"] is items[2]
    assert kept["clipped"].text_content == "It dropped from about 33"
    assert all(INTERRUPTED_MARKER not in (m.text_content or "") for m in ctx.items)


def test_recent_updates_drops_a_repeat_inside_the_window_only() -> None:
    from happy_voice.context import RecentUpdates

    r = RecentUpdates(window=2.0)
    tool = "New messages in session: abc\n\nClaude Code is using Read - sources/sync/sync.ts"
    assert r.is_repeat(tool, 100.0) is False
    # the sync layer re-renders the same tool call when its result lands, 1 ms later
    assert r.is_repeat(tool, 100.001) is True
    # a different update in between is not affected
    assert r.is_repeat("Session became focused: abc", 100.002) is False
    assert r.is_repeat(tool, 100.5) is True
    # past the window the same text is taken at face value: the file really can be read twice
    assert r.is_repeat(tool, 103.0) is False
    # whitespace is not a difference
    assert r.is_repeat(f"  {tool}\n", 103.1) is True


def test_recent_updates_does_not_grow_without_bound() -> None:
    from happy_voice.context import RecentUpdates

    r = RecentUpdates(window=2.0, keep=4)
    for i in range(50):
        assert r.is_repeat(f"update {i}", 100.0 + i * 0.01) is False
    assert len(r._seen) <= 4


def test_focused_session_takes_last_match() -> None:
    assert focused_session_from("Session became focused: a\nSession became focused: b") == "b"
    assert focused_session_from("nothing here") is None


def test_build_instructions_order() -> None:
    text = build_instructions(app_system_prompt="APP PROMPT", session_id="sess1", language="fr")
    assert text.startswith(BASE_PROMPT.strip()[:40])
    assert text.index("sess1") < text.index("APP PROMPT")
    assert "APP PROMPT" in text


def test_answering_is_the_default_and_outranks_the_app_prompt() -> None:
    # voiceSystemPrompt.ts says "You only respond when asked directly like 'Happy, ...'", which
    # cost a user three dropped questions on 2026-10-29. Our override has to come after it.
    text = build_instructions(app_system_prompt="APP PROMPT", session_id=None, language=None)
    assert "# When to answer" in text
    assert text.index("APP PROMPT") < text.index("# When to answer")
    # it is there even with no app prompt to override
    assert "# When to answer" in build_instructions(
        app_system_prompt=None, session_id=None, language=None
    )
    # and the name section still gets the last word
    named = build_instructions(app_system_prompt=None, session_id=None, language=None, name="Morgan")
    assert named.index("# When to answer") < named.index("Your name is Morgan")


def test_skip_turn_is_described_as_the_exception_not_the_default() -> None:
    description = SKIP_TURN_SCHEMA["description"]
    assert "only when" in description
    # a missing wake word is not grounds to skip, and neither is a repeated question
    assert "name" in description and "again" in description


def test_voice_name_derives_from_voice_id() -> None:
    assert voice_name("af_bella") == "Bella"
    assert voice_name("bf_emma") == "Emma"
    assert voice_name("bm_lewis") == "Lewis"
    # blends answer to the first voice
    assert voice_name("am_michael(2)+am_onyx(1)") == "Michael"
    # overrides beat id derivation
    assert voice_name("am_morgan") == "Morgan Freeman"
    # no resolvable name -> Happy
    assert voice_name("zz") == "Happy"
    assert voice_name("am") == "Happy"
    assert voice_name("") == "Happy"
    assert voice_name(None) == "Happy"
    assert voice_name("bogus(0)") == "Happy"


def test_persona_only_follows_a_voice_that_was_asked_for() -> None:
    # No voice requested: the server default is nameless, however it is configured.
    assert persona_for(None, "af_heart", KOKORO) == "Happy"
    # Requested and honoured: the voice lends its name.
    assert persona_for("bm_george", "bm_george", KOKORO) == "George"
    assert persona_for("am_morgan", "am_morgan", KOKORO + ["am_morgan"]) == "Morgan Freeman"
    # A blend asked for and honoured answers to its first voice, as voice_name says.
    assert persona_for("am_michael(2)+am_onyx(1)", "am_michael(2)+am_onyx(1)", KOKORO) == "Michael"
    # Overridden by resolve_tts -- an unknown voice, or any voice on a non-English
    # conversation -- so the voice being spoken is not the one named.
    assert persona_for("af_nope", "af_heart", KOKORO) == "Happy"
    assert persona_for("bm_george", "ef_dora", KOKORO) == "Happy"


def test_name_section_is_last_and_happy_is_omitted() -> None:
    text = build_instructions(app_system_prompt="APP PROMPT", session_id=None, language="en", name="Morgan")
    assert "Your name is Morgan" in text
    assert "or Happy" in text
    # appended after the app prompt, so it overrides the app's address rules
    assert text.index("APP PROMPT") < text.index("Your name is Morgan")
    assert text.endswith("answer them.")
    assert "Your name" not in build_instructions(app_system_prompt=None, session_id=None, language=None, name="Happy")
    assert "Your name" not in build_instructions(app_system_prompt=None, session_id=None, language=None)


def test_tool_schemas_have_no_client_scope_params() -> None:
    for schema in (SEND_MESSAGE_SCHEMA, PERMISSION_SCHEMA):
        props = schema["parameters"]["properties"]
        assert not {"client_id", "clientId", "email"} & set(props)
    assert PERMISSION_SCHEMA["parameters"]["properties"]["decision"]["enum"] == ["allow", "deny"]


def test_voice_config_tolerates_bad_payloads() -> None:
    assert VoiceConfig.from_json("").language == "en"
    assert VoiceConfig.from_json("[]").system_prompt == ""
    cfg = VoiceConfig.from_json('{"systemPrompt": "p", "firstMessage": 3, "language": "es"}')
    assert (cfg.system_prompt, cfg.first_message, cfg.language) == ("p", "", "es")


def test_settings_voice_mapping() -> None:
    os.environ.pop("TTS_VOICE", None)
    s = Settings()
    assert s.voice_for("en") == "af_heart"
    assert s.voice_for("es") == "ef_dora"
    assert s.voice_for("pt-BR") == "pf_dora"
    assert s.voice_for("de") == "af_heart"
    assert s.llm_extra_body == {"chat_template_kwargs": {"enable_thinking": False}}


def test_scripted_reply_marker() -> None:
    m = _SCRIPTED_REPLY_RE.search("Message sent. [DO NOT say anything else, simply say 'sent']")
    assert m and m.group(1) == "sent"
    assert _SCRIPTED_REPLY_RE.search("Message sent to session sess_42.") is None
    # only a trailing marker counts
    assert _SCRIPTED_REPLY_RE.search("[DO NOT say anything else, simply say 'ok'] then more") is None



def test_announces_interrupted_speech_only() -> None:
    class Session:
        def on(self, event):
            def register(fn):
                self.handler = (event, fn)
                return fn
            return register

    class Handle:
        def __init__(self, interrupted: bool) -> None:
            self.interrupted = interrupted

        def add_done_callback(self, fn) -> None:
            self.done = fn

    sent: list[tuple[bytes, dict]] = []

    async def publish(data: bytes, **kwargs) -> None:
        sent.append((data, kwargs))

    async def run() -> None:
        session = Session()
        announce_interruptions(session, publish)
        event, on_speech = session.handler
        assert event == "speech_created"
        for interrupted in (False, True):
            handle = Handle(interrupted)
            on_speech(type("Ev", (), {"speech_handle": handle})())
            handle.done(handle)
        await asyncio.sleep(0)

    asyncio.run(run())
    assert sent == [(b"", {"reliable": True, "topic": TOPIC_INTERRUPTED})]
    assert TOPIC_INTERRUPTED == "happy.interrupted"


KOKORO = ["af_heart", "af_bella", "am_michael", "am_onyx", "bm_george", "af_v0bella"]


def test_voice_config_reads_voice_and_speed() -> None:
    cfg = VoiceConfig.from_json('{"voice": "am_michael(2)+am_onyx(1)", "speed": 0.85}')
    assert cfg.voice == "am_michael(2)+am_onyx(1)"
    assert cfg.speed == 0.85
    cfg = VoiceConfig.from_json('{"voice": "", "speed": "fast"}')
    assert cfg.voice is None and cfg.speed is None
    cfg = VoiceConfig.from_json('{"speed": true, "voice": 7}')
    assert cfg.voice is None and cfg.speed is None
    assert VoiceConfig.from_json("").voice is None


def test_parse_voice() -> None:
    assert parse_voice("af_heart") == [("af_heart", 1)]
    assert parse_voice("am_michael(2)+am_onyx(1)") == [("am_michael", 2), ("am_onyx", 1)]
    assert parse_voice("a(1)+b(1)+c(1)+d(1)") is not None
    assert parse_voice("a(1)+b(1)+c(1)+d(1)+e(1)") is None  # too many parts
    assert parse_voice("am_michael(0)+am_onyx(1)") is None  # weight must be positive
    assert parse_voice("am_michael(-1)+am_onyx(1)") is None
    assert parse_voice("am_michael(1.5)+am_onyx(1)") is None
    assert parse_voice("am_michael+am_onyx") is None  # blend parts need weights
    assert parse_voice("af_heart(1)") is None
    assert parse_voice("") is None
    assert parse_voice("../etc/passwd") is None
    assert parse_voice("AF_HEART") is None


def test_validate_voice_against_kokoro_list() -> None:
    assert validate_voice("af_heart", KOKORO) == "af_heart"
    assert validate_voice(" am_michael(2) + am_onyx(1) ", KOKORO) == "am_michael(2)+am_onyx(1)"
    assert validate_voice("af_v0bella", KOKORO) == "af_v0bella"
    assert validate_voice("af_nope", KOKORO) is None
    assert validate_voice("am_michael(2)+am_nope(1)", KOKORO) is None
    assert validate_voice(None, KOKORO) is None
    assert validate_voice(3, KOKORO) is None


def test_validate_voice_pattern_fallback() -> None:
    assert validate_voice("af_anything", None) == "af_anything"
    assert validate_voice("am_michael(2)+am_onyx(1)", None) == "am_michael(2)+am_onyx(1)"
    assert validate_voice("af_v0bella", None) is None
    assert validate_voice("heart", None) is None


def test_clamp_speed() -> None:
    assert clamp_speed(0.85) == 0.85
    assert clamp_speed(1) == 1.0
    assert clamp_speed(0.1) == 0.5
    assert clamp_speed(9) == 1.5
    assert clamp_speed(float("nan")) is None
    assert clamp_speed(float("inf")) is None
    assert clamp_speed(True) is None
    assert clamp_speed("1.0") is None


def test_resolve_tts() -> None:
    s = Settings()
    s.tts_voice = "af_heart"
    s.tts_speed = 1.0
    assert resolve_tts(s, "en", None, None, KOKORO) == ("af_heart", 1.0)
    assert resolve_tts(s, "en", "am_michael(2)+am_onyx(1)", 0.85, KOKORO) == ("am_michael(2)+am_onyx(1)", 0.85)
    assert resolve_tts(s, "en", "bm_george", None, KOKORO) == ("bm_george", 1.0)
    assert resolve_tts(s, "en", "bm_george", 3, KOKORO) == ("bm_george", 1.5)
    assert resolve_tts(s, None, "bm_george", 0.2, KOKORO) == ("bm_george", 0.5)
    # invalid voice: server defaults for both
    assert resolve_tts(s, "en", "af_nope", 0.8, KOKORO) == ("af_heart", 1.0)
    # speed only
    assert resolve_tts(s, "en", None, 1.2, KOKORO) == ("af_heart", 1.2)
    assert resolve_tts(s, "en", None, "x", KOKORO) == ("af_heart", 1.0)
    # other languages keep their language voice
    assert resolve_tts(s, "es", "bm_george", 0.9, KOKORO) == ("ef_dora", 1.0)


def test_kokoro_voice_list_shapes() -> None:
    assert _voice_names({"voices": ["af_heart", "am_onyx"]}) == {"af_heart", "am_onyx"}
    assert _voice_names({"voices": [{"id": "af_heart", "name": "af_heart"}]}) == {"af_heart"}
    assert _voice_names({"voices": []}) is None
    assert _voice_names("nope") is None


def test_fetch_known_voices_failure_is_not_cached() -> None:
    voices._known_voices = None
    # nothing listens on port 9 (discard); the fetch fails fast and is retried next time
    assert asyncio.run(voices.fetch_known_voices("http://127.0.0.1:9/v1", timeout=1.0)) is None
    assert voices._known_voices is None
    voices._known_voices = frozenset({"af_heart"})
    assert asyncio.run(voices.fetch_known_voices("http://127.0.0.1:9/v1")) == {"af_heart"}
    voices._known_voices = None


class _FakeStream:
    def __init__(self, owner: "_FakeLLM", chunks: int) -> None:
        self._owner = owner
        self._left = chunks

    def __aiter__(self):
        return self

    async def __anext__(self):
        await asyncio.sleep(self._owner.delay)
        if self._owner.fail:
            raise RuntimeError("llm down")
        if self._left <= 0:
            raise StopAsyncIteration
        self._left -= 1
        self._owner.chunks_read += 1
        if self._owner.text is None:
            return object()
        # a text reply, streamed as `.delta.content` pieces like a real LLMStream
        piece = self._owner.text[len(self._owner.text) - self._left - 1]
        return llm.ChatChunk(id="c", delta=llm.ChoiceDelta(role="assistant", content=piece))

    async def aclose(self) -> None:
        self._owner.closed_streams += 1


class _FakeLLM:
    def __init__(self, delay: float = 0.0, fail: bool = False, text: str | None = None) -> None:
        self.delay = delay
        self.fail = fail
        # when set, the stream yields this text one character per chunk
        self.text = text
        self.requests: list[tuple[object, object]] = []
        self.kwargs: list[dict] = []
        self.chunks_read = 0
        self.closed_streams = 0
        self.closed = False

    def chat(self, *, chat_ctx, tools, **kwargs):
        self.requests.append((chat_ctx, tools))
        self.kwargs.append(kwargs)
        return _FakeStream(self, chunks=50 if self.text is None else len(self.text))

    async def aclose(self) -> None:
        self.closed = True


def test_eot_prediction_is_relogged_and_other_debug_is_dropped() -> None:
    import logging

    from happy_voice.assistant import _EotPredictionLog

    ours: list[str] = []

    class _Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            ours.append(record.getMessage())

    happy = logging.getLogger("happy-voice")
    handler = _Capture()
    happy.addHandler(handler)
    was = happy.level
    happy.setLevel(logging.INFO)  # the worker's cli does this; nothing configures it here
    try:
        f = _EotPredictionLog()
        eot = logging.LogRecord("livekit.agents", logging.DEBUG, __file__, 1, "eot prediction", (), None)
        eot.probability = 0.42
        eot.unlikely_threshold = 0.15
        eot.endpointing_delay = 1.5
        assert f.filter(eot) is False  # consumed, not forwarded to the library's handlers
        assert ours and "probability=0.42" in ours[0] and "endpointing_delay=1.5" in ours[0]

        noise = logging.LogRecord("livekit.agents", logging.DEBUG, __file__, 1, "chatty %s", ("x",), None)
        assert f.filter(noise) is False  # the rest of DEBUG never reaches a handler
        info = logging.LogRecord("livekit.agents", logging.INFO, __file__, 1, "real news", (), None)
        assert f.filter(info) is True  # anything above DEBUG passes untouched
        assert len(ours) == 1
    finally:
        happy.removeHandler(handler)
        happy.setLevel(was)


def test_warmer_stops_at_first_chunk() -> None:
    async def run() -> _FakeLLM:
        model = _FakeLLM()
        warmer = PrefixWarmer(model, lambda: ("ctx", ["tool"]), debounce=0)
        warmer.schedule()
        await asyncio.sleep(0.05)
        assert warmer.completed == 1
        await warmer.aclose()
        return model

    model = asyncio.run(run())
    assert model.requests == [("ctx", ["tool"])]
    assert model.chunks_read == 1
    assert model.closed_streams == 1
    assert model.closed


def test_warmer_debounces_and_supersedes_bursts() -> None:
    snapshots = iter(["first", "second", "third"])

    async def run() -> tuple[_FakeLLM, PrefixWarmer]:
        model = _FakeLLM()
        warmer = PrefixWarmer(model, lambda: (next(snapshots), []), debounce=0.02)
        for _ in range(3):  # a burst of context updates
            warmer.schedule()
        await asyncio.sleep(0.1)
        await warmer.aclose()
        return model, warmer

    model, warmer = asyncio.run(run())
    assert [ctx for ctx, _ in model.requests] == ["first"]
    assert warmer.completed == 1


def test_warmer_cancels_a_stale_request_in_flight() -> None:
    async def run() -> tuple[_FakeLLM, PrefixWarmer]:
        model = _FakeLLM(delay=0.05)
        n = iter(range(10))
        warmer = PrefixWarmer(model, lambda: (next(n), []), debounce=0)
        warmer.schedule()
        await asyncio.sleep(0.01)  # first request is prefilling
        warmer.schedule()
        await asyncio.sleep(0.15)
        await warmer.aclose()
        return model, warmer

    model, warmer = asyncio.run(run())
    assert [ctx for ctx, _ in model.requests] == [0, 1]
    assert model.closed_streams == 2  # the stale stream is closed, not left running
    assert warmer.completed == 1


def test_turn_drops_a_warm_up_that_cannot_finish_in_the_budget() -> None:
    # A 0.2 s warm-up with a 0.05 s budget: the first turn has no history to judge by and so
    # waits out the budget (and loses it, as the 2026-10-29 session did twice), but the second
    # knows what a warm-up costs here and drops it at once instead of buying more dead air.
    async def run() -> tuple[PrefixWarmer, float, float]:
        warmer = PrefixWarmer(_FakeLLM(delay=0.2), lambda: ("ctx", []), debounce=0, turn_wait=0.05)
        warmer.schedule()
        await asyncio.sleep(0.01)
        blind = time.monotonic()
        await warmer.begin_turn()
        blind = time.monotonic() - blind
        warmer.end_turn()
        # let one warm-up finish, so there is a duration to judge by
        warmer.schedule()
        await asyncio.sleep(0.25)
        assert warmer.completed == 1
        warmer.schedule()
        await asyncio.sleep(0.01)
        informed = time.monotonic()
        await warmer.begin_turn()
        informed = time.monotonic() - informed
        warmer.end_turn()
        await warmer.aclose()
        return warmer, blind, informed

    warmer, blind, informed = asyncio.run(run())
    assert blind >= 0.05  # waited out the whole budget
    assert informed < 0.02  # dropped it immediately


def test_turn_still_waits_for_a_warm_up_about_to_land() -> None:
    # Same budget, but the warm-up takes 20 ms: waiting is what caches the prefix, so the turn
    # must still do it rather than racing its own request against the one in flight.
    async def run() -> tuple[PrefixWarmer, int]:
        warmer = PrefixWarmer(_FakeLLM(delay=0.02), lambda: ("ctx", []), debounce=0, turn_wait=0.05)
        warmer.schedule()
        await asyncio.sleep(0.05)
        assert warmer.completed == 1
        warmer.schedule()
        await asyncio.sleep(0.005)  # its request is out and nearly done
        await warmer.begin_turn()
        warmer.end_turn()
        completed = warmer.completed
        await warmer.aclose()
        return warmer, completed

    _, completed = asyncio.run(run())
    assert completed == 2  # waited, and the warm-up finished rather than being cancelled


def test_warmer_failure_is_swallowed() -> None:
    async def run() -> PrefixWarmer:
        warmer = PrefixWarmer(_FakeLLM(fail=True), lambda: ("ctx", []), debounce=0)
        warmer.schedule()
        await asyncio.sleep(0.05)
        await warmer.aclose()
        return warmer

    assert asyncio.run(run()).completed == 0


def test_warmup_snapshot_matches_the_turn_request() -> None:
    from livekit.agents import Agent, function_tool

    from happy_voice.assistant import warmup_snapshot

    @function_tool
    async def ping() -> str:
        """Ping."""
        return "pong"

    ctx = llm.ChatContext.empty()
    ctx.add_message(role="system", content="instructions")
    ctx.add_message(role="system", content="initial context")
    ctx.add_message(role="assistant", content="Hi")
    ctx.add_message(role="system", content="Session became focused: abc")
    agent = Agent(instructions="instructions", chat_ctx=ctx, tools=[ping])
    warm_ctx, tools = warmup_snapshot(agent)
    msgs = [m for m in warm_ctx.items if isinstance(m, llm.ChatMessage)]
    assert [m.role for m in msgs] == ["system", "assistant", "user"]
    assert msgs[0].text_content.startswith("instructions")
    assert [t.info.name for t in tools] == ["ping"]
    # the snapshot is a copy: the agent's own history is untouched
    assert len(agent.chat_ctx.items) == 4


def test_warmup_snapshot_adds_a_user_turn_before_the_user_speaks() -> None:
    from livekit.agents import Agent

    from happy_voice.assistant import WARMUP_PLACEHOLDER, warmup_snapshot

    ctx = llm.ChatContext.empty()
    ctx.add_message(role="system", content="instructions")
    ctx.add_message(role="assistant", content="Hi")
    agent = Agent(instructions="instructions", chat_ctx=ctx)
    warm_ctx, tools = warmup_snapshot(agent)
    msgs = [m for m in warm_ctx.items if isinstance(m, llm.ChatMessage)]
    assert [(m.role, m.text_content) for m in msgs] == [
        ("system", "instructions"),
        ("assistant", "Hi"),
        ("user", WARMUP_PLACEHOLDER),
    ]
    assert tools == []
    assert len(agent.chat_ctx.items) == 2


_TUNING_ENV = (
    "LLM_TIMEOUT",
    "LLM_MAX_RETRY",
    "LLM_BASE_URL",
    "LLM_MODEL",
    "MAX_ENDPOINTING_DELAY",
    "INTERRUPT_MIN_DURATION",
    "INTERRUPT_MIN_WORDS",
    "FALSE_INTERRUPTION_TIMEOUT",
    "RESUME_FALSE_INTERRUPTION",
)


def _settings_with(**env: str) -> Settings:
    saved = {k: os.environ.pop(k, None) for k in _TUNING_ENV}
    try:
        os.environ.update(env)
        return Settings()
    finally:
        for k in _TUNING_ENV:
            os.environ.pop(k, None)
            if saved[k] is not None:
                os.environ[k] = saved[k]


def test_llm_and_interruption_defaults() -> None:
    s = _settings_with()
    # agentgateway's virtual `coder`, leaving the backend to the gateway: voice does not name a
    # tier, since naming the MoE one cost it tool calling. Not 8899: that is coder-tool-proxy,
    # which sets stream=False upstream, so a voice turn would wait for the whole answer before
    # the first word is spoken. See happy_voice/config.py.
    assert (s.llm_base_url, s.llm_model) == ("http://127.0.0.1:8903/v1", "coder")
    assert s.llm_timeout == 60.0
    assert s.llm_max_retry == 0
    assert s.max_endpointing_delay == 0.8
    assert s.interrupt_min_duration == 0.8
    assert s.interrupt_min_words == 1
    assert s.false_interruption_timeout == 2.0
    assert s.resume_false_interruption is True


def test_llm_and_interruption_env_overrides() -> None:
    s = _settings_with(
        LLM_TIMEOUT="90",
        LLM_MAX_RETRY="2",
        INTERRUPT_MIN_DURATION="0.6",
        INTERRUPT_MIN_WORDS="3",
        FALSE_INTERRUPTION_TIMEOUT="off",
        RESUME_FALSE_INTERRUPTION="false",
    )
    assert s.llm_timeout == 90.0
    assert s.llm_max_retry == 2
    assert s.interrupt_min_duration == 0.6
    assert s.interrupt_min_words == 3
    assert s.false_interruption_timeout is None
    assert s.resume_false_interruption is False
    assert _settings_with(FALSE_INTERRUPTION_TIMEOUT="0").false_interruption_timeout is None
    assert _settings_with(FALSE_INTERRUPTION_TIMEOUT="1.25").false_interruption_timeout == 1.25


def test_bad_tuning_values_fall_back_to_defaults() -> None:
    s = _settings_with(
        LLM_TIMEOUT="soon",
        LLM_MAX_RETRY="-1",
        INTERRUPT_MIN_DURATION="nan",
        INTERRUPT_MIN_WORDS="two",
        FALSE_INTERRUPTION_TIMEOUT="later",
    )
    assert s.llm_timeout == 60.0
    assert s.llm_max_retry == 0
    assert s.interrupt_min_duration == 0.8
    assert s.interrupt_min_words == 1
    assert s.false_interruption_timeout == 2.0
    # below the 1 s floor a timeout would fail every request
    assert _settings_with(LLM_TIMEOUT="0").llm_timeout == 60.0


def test_session_options_follow_settings() -> None:
    from happy_voice.assistant import llm_conn_options, turn_handling

    s = _settings_with(LLM_TIMEOUT="45", INTERRUPT_MIN_WORDS="2")
    s.turn_detector = "vad"  # no model download in unit tests
    opts = llm_conn_options(s)
    assert (opts.timeout, opts.max_retry) == (45.0, 0)
    th = turn_handling(s)
    assert th["interruption"] == {
        "enabled": True,
        "mode": "vad",
        "min_duration": 0.8,
        "min_words": 2,
        "false_interruption_timeout": 2.0,
        "resume_false_interruption": True,
    }
    assert th["endpointing"] == {"min_delay": 0.4, "max_delay": 0.8}


def test_warmer_passes_conn_options() -> None:
    from livekit.agents import APIConnectOptions

    opts = APIConnectOptions(max_retry=0, timeout=60.0)

    async def run() -> _FakeLLM:
        model = _FakeLLM()
        warmer = PrefixWarmer(model, lambda: ("ctx", []), debounce=0, conn_options=opts)
        warmer.schedule()
        await asyncio.sleep(0.05)
        await warmer.aclose()
        return model

    assert asyncio.run(run()).kwargs == [{"conn_options": opts}]


def test_turn_waits_for_the_warmup_in_flight() -> None:
    async def run() -> tuple[float, PrefixWarmer, _FakeLLM]:
        model = _FakeLLM(delay=0.1)
        warmer = PrefixWarmer(model, lambda: ("ctx", []), debounce=0)
        warmer.schedule()
        await asyncio.sleep(0.02)  # the warm-up is prefilling
        t = asyncio.get_running_loop().time()
        await warmer.begin_turn()
        waited = asyncio.get_running_loop().time() - t
        warmer.end_turn()
        await warmer.aclose()
        return waited, warmer, model

    waited, warmer, model = asyncio.run(run())
    assert waited >= 0.05
    assert warmer.completed == 1  # finished, not cancelled: the turn reuses its prefix
    assert len(model.requests) == 1


def test_turn_gives_up_on_a_slow_warmup_and_cancels_it() -> None:
    # The reason the agent went mute: begin_turn() used to wait the whole LLM timeout, so a
    # slow warm-up held the reply back for seconds. Past `turn_wait` the turn goes out and the
    # warm-up is cancelled, so the two never prefill side by side.
    async def run() -> tuple[float, PrefixWarmer, _FakeLLM]:
        model = _FakeLLM(delay=5.0)
        warmer = PrefixWarmer(model, lambda: ("ctx", []), debounce=0, timeout=60.0, turn_wait=0.05)
        warmer.schedule()
        await asyncio.sleep(0.02)  # the warm-up is prefilling and will not finish in time
        t = asyncio.get_running_loop().time()
        await warmer.begin_turn()
        waited = asyncio.get_running_loop().time() - t
        warmer.end_turn()
        await asyncio.sleep(0.02)  # let the cancellation unwind
        await warmer.aclose()
        return waited, warmer, model

    waited, warmer, model = asyncio.run(run())
    assert waited < 0.3  # not the 60 s timeout
    assert warmer.completed == 0
    assert model.closed_streams == 1  # cancelled, not left in flight


def test_turn_drops_a_warmup_not_yet_sent() -> None:
    async def run() -> tuple[PrefixWarmer, _FakeLLM]:
        model = _FakeLLM()
        warmer = PrefixWarmer(model, lambda: ("ctx", []), debounce=0.05)
        warmer.schedule()
        await warmer.begin_turn()  # still debouncing
        warmer.end_turn()
        await asyncio.sleep(0.1)
        await warmer.aclose()
        return warmer, model

    warmer, model = asyncio.run(run())
    assert model.requests == []
    assert warmer.completed == 0


def test_turn_right_after_a_superseding_update_does_not_wait() -> None:
    # A context update supersedes a warm-up that is prefilling and a text turn follows at
    # once: the new warm-up is only debouncing, so the turn must not wait for it (it would in
    # turn wait for the turn to end).
    async def run() -> tuple[float, list]:
        model = _FakeLLM(delay=0.2)
        n = iter(range(10))
        warmer = PrefixWarmer(model, lambda: (next(n), []), debounce=0.01, timeout=2.0)
        warmer.schedule()
        await asyncio.sleep(0.05)  # warm-up 0 is prefilling
        warmer.schedule()  # supersedes it; its cancellation has not unwound yet
        t = asyncio.get_running_loop().time()
        await warmer.begin_turn()
        waited = asyncio.get_running_loop().time() - t
        warmer.end_turn()
        await asyncio.sleep(0.05)
        await warmer.aclose()
        return waited, [ctx for ctx, _ in model.requests]

    waited, requests = asyncio.run(run())
    assert waited < 0.1
    assert requests == [0]


def test_warmup_scheduled_during_a_turn_waits_for_it() -> None:
    async def run() -> tuple[int, int]:
        model = _FakeLLM()
        warmer = PrefixWarmer(model, lambda: ("ctx", []), debounce=0)
        await warmer.begin_turn()
        warmer.schedule()  # a context update arrives while the turn is generating
        await asyncio.sleep(0.05)
        during = len(model.requests)
        warmer.end_turn()
        await asyncio.sleep(0.05)
        after = len(model.requests)
        await warmer.aclose()
        return during, after

    assert asyncio.run(run()) == (0, 1)


def test_long_duplicate_context_updates_are_detected() -> None:
    from happy_voice.context import DUPLICATE_MIN_CHARS, already_in_context

    dump = "# Session ID: abc\n\n" + "Claude Code: did a thing.\n" * 100
    assert len(dump) >= DUPLICATE_MIN_CHARS
    ctx = llm.ChatContext.empty()
    ctx.add_message(role="system", content="instructions\n\nCURRENT SESSION:\n\n" + dump)
    assert already_in_context(dump, ctx)
    assert already_in_context("\n" + dump + "\n", llm.ChatContext.empty(), instructions="x" + dump)
    assert not already_in_context(dump + "Claude Code: one more.", ctx)
    # short updates are events that may repeat on purpose
    ctx.add_message(role="system", content="Session became focused: abc")
    assert not already_in_context("Session became focused: abc", ctx)


def _pcm(*runs: tuple[int, float]) -> bytes:
    """Concatenate (milliseconds, amplitude) runs as 24 kHz mono s16le, alternating sign.

    Alternating keeps the rms equal to the amplitude, so a run's amplitude is exactly the
    level the onset search sees.
    """
    out = bytearray()
    for ms, amp in runs:
        for n in range(24 * ms):
            x = int(amp) if n % 2 == 0 else -int(amp)
            out += (x & 0xFFFF).to_bytes(2, "little")
    return bytes(out)


def test_onset_skips_the_kokoro_lead_and_finds_the_speech() -> None:
    from happy_voice.tts_trim import find_speech_onset

    # the shape tts_lead_sweep.py measures: a burst rising to rms ~900, a decay, then a
    # near-silent valley -- 750 ms of it -- and only then the speech
    lead = _pcm((50, 8), (250, 900), (200, 400), (250, 80))
    onset = find_speech_onset(lead + _pcm((500, 4000)), sample_rate=24000)
    assert onset is not None
    # within two 10 ms windows of the end of the valley
    assert abs(onset - len(lead)) <= 24000 // 100 * 2 * 2


def test_onset_ignores_audio_at_the_artifact_level() -> None:
    from happy_voice.tts_trim import find_speech_onset

    # 1005 is the loudest level any pre-speech artifact holds over two windows; the quietest
    # unmistakable speech holds 1096. An artifact alone must not read as speech.
    assert find_speech_onset(_pcm((700, 1000)), sample_rate=24000) is None


def test_onset_cuts_at_the_end_of_the_valley_not_its_quietest_window() -> None:
    from happy_voice.tts_trim import find_speech_onset

    # The artifact fades *in*, so its own first windows (rms 5) are quieter than the valley
    # floor it later decays into (80). Cutting at the quietest window would trim nothing.
    lead = _pcm((40, 5), (300, 900), (200, 400), (250, 80))
    onset = find_speech_onset(lead + _pcm((500, 4000)), sample_rate=24000)
    assert onset is not None
    assert abs(onset - len(lead)) <= 24000 // 100 * 2 * 2


def test_one_loud_window_is_a_click_two_are_speech() -> None:
    from happy_voice.tts_trim import find_speech_onset

    window = 24000 // 100 * 2  # bytes in one 10 ms window
    valley = _pcm((500, 80))
    assert find_speech_onset(valley + _pcm((10, 4000)) + _pcm((300, 80)), sample_rate=24000) is None
    # the cut is the start of the valley's last window, so one window short of the speech
    onset = find_speech_onset(valley + _pcm((20, 4000)) + _pcm((300, 80)), sample_rate=24000)
    assert onset == len(valley) - window


def test_speech_with_no_valley_in_front_of_it_is_kept_whole() -> None:
    from happy_voice.tts_trim import find_speech_onset

    # 600 never drops to VALLEY_CEILING: this is speech already running, not a lead.
    assert find_speech_onset(_pcm((700, 600), (300, 4000)), sample_rate=24000) == 0


def test_a_quiet_stretch_too_early_to_be_a_lead_is_kept() -> None:
    from happy_voice.tts_trim import find_speech_onset

    # 180 ms in, this is a stop closure inside the speech, not the 680-910 ms artifact --
    # cutting there would drop the opening word.
    assert find_speech_onset(_pcm((100, 900), (80, 50), (300, 4000)), sample_rate=24000) == 0


def test_onset_at_the_very_first_sample_is_zero_not_falsy_none() -> None:
    from happy_voice.tts_trim import find_speech_onset

    assert find_speech_onset(_pcm((200, 4000)), sample_rate=24000) == 0


def test_silence_has_no_onset_so_the_caller_keeps_it() -> None:
    from happy_voice.tts_trim import find_speech_onset

    assert find_speech_onset(bytes(24000 * 2), sample_rate=24000) is None
    # shorter than one window: still searching, nothing to report
    assert find_speech_onset(_pcm((5, 9000)), sample_rate=24000) is None


def test_the_scan_is_the_same_over_arbitrary_chunk_boundaries() -> None:
    from happy_voice.tts_trim import _OnsetScanner, find_speech_onset

    pcm = _pcm((50, 8), (250, 900), (200, 400), (250, 80), (500, 4000))
    scanner = _OnsetScanner(24000)
    # 7 bytes is not a whole sample, let alone a whole window
    for i in range(0, len(pcm), 7):
        scanner.push(pcm[i : i + 7])
        if scanner.cut_offset() is not None:
            break
    assert scanner.cut_offset() == find_speech_onset(pcm, sample_rate=24000)


# --- history compaction (happy_voice/compaction.py) ------------------------------------------

_COMPACTION_ENV = (
    "VOICE_COMPACTION",
    "VOICE_COMPACT_TRIGGER",
    "VOICE_COMPACT_KEEP",
    "VOICE_CONTEXT_HARD_CAP",
    "VOICE_COMPACT_SUMMARY_TOKENS",
)


def _compaction_settings(**env: str) -> Settings:
    saved = {k: os.environ.pop(k, None) for k in _COMPACTION_ENV}
    try:
        os.environ.update(env)
        return Settings()
    finally:
        for k in _COMPACTION_ENV:
            os.environ.pop(k, None)
            if saved[k] is not None:
                os.environ[k] = saved[k]


def test_compaction_settings_defaults_overrides_and_bad_order() -> None:
    s = _compaction_settings()
    assert s.compaction is True
    assert (s.compact_keep, s.compact_trigger, s.context_hard_cap) == (8000, 32000, 235929)
    assert s.compact_summary_tokens == 1200
    s = _compaction_settings(
        VOICE_COMPACTION="0",
        VOICE_COMPACT_TRIGGER="30000",
        VOICE_COMPACT_KEEP="10000",
        VOICE_CONTEXT_HARD_CAP="50000",
        VOICE_COMPACT_SUMMARY_TOKENS="300",
    )
    assert s.compaction is False
    assert (s.compact_keep, s.compact_trigger, s.context_hard_cap) == (10000, 30000, 50000)
    assert s.compact_summary_tokens == 300
    assert _compaction_settings(VOICE_COMPACT_KEEP="lots").compact_keep == 8000


def test_compaction_never_keeps_less_than_the_floor() -> None:
    from happy_voice.config import COMPACT_KEEP_FLOOR

    assert COMPACT_KEEP_FLOOR == 8000
    s = _compaction_settings(VOICE_COMPACT_KEEP="2000")
    assert s.compact_keep == 8000 and s.compaction is True
    # a trigger with no room above the floor turns compaction off; keep is not lowered to fit
    s = _compaction_settings(VOICE_COMPACT_TRIGGER="9000")
    assert (s.compact_keep, s.compact_trigger) == (8000, 9000) and s.compaction is False
    s = _compaction_settings(VOICE_COMPACT_TRIGGER="8000", VOICE_COMPACT_KEEP="2000")
    assert (s.compact_keep, s.compact_trigger) == (8000, 8000) and s.compaction is False


def test_compaction_settings_fit_under_a_valid_hard_cap() -> None:
    # KEEP < TRIGGER < HARD_CAP must hold; a valid cap is kept and the others lowered to fit
    s = _compaction_settings(VOICE_CONTEXT_HARD_CAP="20000")
    assert (s.compact_keep, s.compact_trigger, s.context_hard_cap) == (8000, 15000, 20000)
    assert s.compaction is True
    s = _compaction_settings(VOICE_COMPACT_TRIGGER="300000")
    assert (s.compact_keep, s.compact_trigger, s.context_hard_cap) == (8000, 32000, 235929)
    # a keep at or over the trigger is not lowered: compaction is off instead
    s = _compaction_settings(VOICE_COMPACT_TRIGGER="20000", VOICE_COMPACT_KEEP="20000")
    assert (s.compact_keep, s.compact_trigger, s.context_hard_cap) == (20000, 20000, 235929)
    assert s.compaction is False
    s = _compaction_settings(VOICE_CONTEXT_HARD_CAP="1")
    assert s.context_hard_cap == 1 and s.compact_trigger < 1 and s.compaction is False
    assert s.compact_keep == 8000
    # the summary must be well under what it replaces, or compaction is turned off
    s = _compaction_settings(VOICE_COMPACT_TRIGGER="10000", VOICE_COMPACT_KEEP="8000")
    assert s.compact_summary_tokens == 1200 and s.compaction is False
    s = _compaction_settings(
        VOICE_COMPACT_TRIGGER="10000", VOICE_COMPACT_KEEP="8000", VOICE_COMPACT_SUMMARY_TOKENS="999"
    )
    assert s.compaction is True
    s = _compaction_settings(
        VOICE_COMPACT_TRIGGER="10000", VOICE_COMPACT_KEEP="8000", VOICE_COMPACT_SUMMARY_TOKENS="1000"
    )
    assert s.compaction is False
    # the summary limit and the backstop stay as given even when compaction is turned off
    assert (s.compact_keep, s.compact_trigger, s.context_hard_cap) == (8000, 10000, 235929)


def _ping_tool():
    from livekit.agents import function_tool

    @function_tool
    async def ping() -> str:
        """Ping."""
        return "pong"

    return ping


def _history(turns: int, *, words: int = 40, tool_every: int = 3) -> llm.ChatContext:
    """instructions, the app's initial context, a greeting, then `turns` exchanges: some carry
    a tool call and its result, and a context update follows every other one."""
    from happy_voice.compaction import INSTRUCTIONS_MESSAGE_ID

    t = 1000.0
    ctx = llm.ChatContext.empty()

    def at() -> float:
        nonlocal t
        t += 1.0
        return t

    ctx.add_message(role="system", content="instructions", id=INSTRUCTIONS_MESSAGE_ID, created_at=at())
    ctx.add_message(role="system", content="Conversation history so far:\nsess_1 is open", created_at=at())
    ctx.add_message(role="assistant", content="Hi, Happy here", created_at=at())
    filler = " ".join(["word"] * words)
    for n in range(turns):
        ctx.add_message(role="user", content=f"question {n} {filler}", created_at=at())
        if n % tool_every == 0:
            ctx.items.append(llm.FunctionCall(call_id=f"call_{n}", name="ping", arguments="{}", created_at=at()))
            ctx.items.append(
                llm.FunctionCallOutput(
                    call_id=f"call_{n}", name="ping", output="pong", is_error=False, created_at=at()
                )
            )
        ctx.add_message(role="assistant", content=f"answer {n} {filler}", created_at=at())
        if n % 2 == 1:
            ctx.add_message(role="system", content=f"New messages in session sess_1: step {n}", created_at=at())
    return ctx


def _agent(ctx: llm.ChatContext):
    from livekit.agents import Agent

    return Agent(instructions="instructions", chat_ctx=ctx, tools=[_ping_tool()])


def _estimator():
    from happy_voice.compaction import TokenEstimator

    return TokenEstimator(0.25)


def test_split_keeps_the_tail_budget_on_a_turn_boundary_without_orphaned_calls() -> None:
    from happy_voice.compaction import INSTRUCTIONS_MESSAGE_ID, split_history

    est = _estimator()
    items = _history(30).items
    for keep in (50, 120, 300, 700, 1500):
        split = split_history(items, keep, est)
        assert split is not None, keep
        assert [i.id for i in split.prefix] == [INSTRUCTIONS_MESSAGE_ID]
        assert split.prefix + split.head + split.tail == list(items)
        assert est.total(split.tail) >= keep
        first = split.tail[0]
        # a turn boundary: a user message, or a context update after a finished exchange
        assert isinstance(first, llm.ChatMessage) and first.role in ("user", "system"), keep
        if first.role == "system":
            last = [i for i in split.head if not (isinstance(i, llm.ChatMessage) and i.role == "system")][-1]
            assert not (isinstance(last, llm.ChatMessage) and last.role == "user")
        calls = {i.call_id for i in split.head if isinstance(i, llm.FunctionCall)}
        outputs = {i.call_id for i in split.head if isinstance(i, llm.FunctionCallOutput)}
        assert calls == outputs, keep


def test_split_never_cuts_between_a_call_and_its_result_or_a_question_and_its_reply() -> None:
    from happy_voice.compaction import split_history

    est = _estimator()
    ctx = _history(4, words=5)
    # a long tool result, so the budget runs out right inside the call
    ctx.add_message(role="user", content="run the tests")
    ctx.items.append(llm.FunctionCall(call_id="c_last", name="ping", arguments="{}"))
    ctx.items.append(llm.FunctionCallOutput(call_id="c_last", name="ping", output="x" * 400, is_error=False))
    ctx.add_message(role="assistant", content="done")
    split = split_history(ctx.items, 20, est)
    assert split is not None
    assert split.tail[0].text_content == "run the tests"
    # a context update between a question and its answer is not a boundary
    ctx = _history(4, words=5)
    ctx.add_message(role="user", content="what changed?")
    ctx.add_message(role="system", content="New messages in session sess_1: " + "y" * 200)
    ctx.add_message(role="assistant", content="the tests pass")
    split = split_history(ctx.items, 20, est)
    assert split is not None
    assert split.tail[0].text_content == "what changed?"


def test_split_has_nothing_to_do_when_the_history_fits_the_budget() -> None:
    from happy_voice.compaction import INSTRUCTIONS_MESSAGE_ID, split_history

    est = _estimator()
    assert split_history(_history(2).items, 100_000, est) is None
    ctx = llm.ChatContext.empty()
    ctx.add_message(role="system", content="instructions", id=INSTRUCTIONS_MESSAGE_ID)
    ctx.add_message(role="user", content="x" * 1000)
    assert split_history(ctx.items, 10, est) is None


def test_estimator_calibrates_from_real_usage() -> None:
    from happy_voice.compaction import ITEM_OVERHEAD_TOKENS, TokenEstimator

    est = TokenEstimator()
    ctx = llm.ChatContext.empty()
    ctx.add_message(role="user", content="x" * 1000)
    est.note_request(ctx)
    # the template tags around the one item are taken off before dividing
    est.observe_usage(500 + ITEM_OVERHEAD_TOKENS)
    assert est.tokens_per_char == 0.5
    est.observe_usage(0)  # a request with no usage changes nothing
    assert est.tokens_per_char == 0.5
    est.observe_usage(ITEM_OVERHEAD_TOKENS)  # nor does one that is all overhead
    assert est.tokens_per_char == 0.5


def test_tool_schemas_do_not_inflate_the_calibrated_ratio() -> None:
    from happy_voice.compaction import ITEM_OVERHEAD_TOKENS, TokenEstimator, tool_schema_chars

    tools = [_ping_tool()]
    schema = tool_schema_chars(tools)
    assert schema > 20  # name, description, an empty parameters object
    ctx = llm.ChatContext.empty()
    ctx.add_message(role="user", content="x" * 1000)
    # what the server counts: the text and the schemas at 0.5 tokens a character, plus tags
    prompt_tokens = int((1000 + schema) * 0.5) + ITEM_OVERHEAD_TOKENS
    with_tools = TokenEstimator()
    with_tools.note_request(ctx, tools)
    with_tools.observe_usage(prompt_tokens)
    assert abs(with_tools.tokens_per_char - 0.5) < 0.001
    # left out, the schemas' tokens land on the history's characters and the ratio runs high
    without = TokenEstimator()
    without.note_request(ctx)
    without.observe_usage(prompt_tokens)
    assert without.tokens_per_char > 0.5 + 0.004


def _run_llm_node(agent, chat_ctx) -> list:
    """The ctx llm_node hands to the LLM, with the library's default llm_node stubbed."""
    from livekit.agents import Agent

    seen: list = []
    original = Agent.default.__dict__["llm_node"]

    async def fake(_agent, ctx, tools, model_settings):
        seen.append(ctx)
        if False:
            yield None

    async def run() -> None:
        async for _ in agent.llm_node(chat_ctx, [], None):
            pass

    Agent.default.llm_node = fake
    try:
        asyncio.run(run())
    finally:
        Agent.default.llm_node = original
    return seen


def _dump(ctx: llm.ChatContext) -> str:
    """A history, whole."""
    import json

    return json.dumps([i.model_dump(mode="json") for i in ctx.items], sort_keys=True)


def _wire(ctx: llm.ChatContext) -> str:
    """A request: the messages as sent, and the items they came from. Not created_at, which
    is never sent and which fold_system_messages stamps afresh on the system message."""
    import json

    messages, _ = ctx.to_provider_format("openai")
    items = [i.model_dump(mode="json", exclude={"created_at"}) for i in ctx.items]
    return json.dumps({"messages": messages, "items": items}, sort_keys=True)


def _assistant(settings: Settings, ctx: llm.ChatContext, *, compactor: bool, enabled: bool = True):
    from happy_voice.assistant import ConversationState, HappyAssistant
    from happy_voice.compaction import Compactor

    agent = HappyAssistant(
        instructions="instructions", room=None, state=ConversationState(), settings=settings, chat_ctx=ctx
    )
    if compactor:
        agent.compactor = Compactor(
            agent=lambda: agent,
            summarizer=_FakeLLM(text="never"),
            warm=None,
            lock=asyncio.Lock(),
            quiet=asyncio.Event(),
            trigger=settings.compact_trigger,
            keep=settings.compact_keep,
            summary_tokens=settings.compact_summary_tokens,
            enabled=enabled,
        )
    return agent


def test_llm_node_request_is_byte_identical_when_off_or_below_the_trigger() -> None:
    ctx = _history(12)
    # what llm_node sent before compaction existed: the folded history, nothing else
    expected = _wire(fold_system_messages(ctx))
    off = _compaction_settings(VOICE_COMPACTION="0")
    on = _compaction_settings()
    for settings, has_compactor, enabled in (
        (off, False, False),
        (off, True, False),
        (on, True, True),
    ):
        agent = _assistant(settings, ctx, compactor=has_compactor, enabled=enabled)
        before = _dump(agent.chat_ctx)
        (sent,) = _run_llm_node(agent, ctx)
        assert _wire(sent) == expected, (settings.compaction, has_compactor)
        assert _dump(agent.chat_ctx) == before
        if agent.compactor is not None:
            # below the trigger: nothing is scheduled
            agent.compactor.on_llm_usage(1000, 900)
            assert agent.compactor._task is None


def test_backstop_trims_only_the_request_copy() -> None:
    ctx = _history(40)
    settings = _compaction_settings(
        VOICE_COMPACT_KEEP="10", VOICE_COMPACT_TRIGGER="20", VOICE_CONTEXT_HARD_CAP="400"
    )
    agent = _assistant(settings, ctx, compactor=True, enabled=False)
    agent.compactor.estimator.tokens_per_char = 0.25
    history_before = _dump(agent.chat_ctx)
    ctx_before = _dump(ctx)
    (sent,) = _run_llm_node(agent, ctx)
    assert _dump(agent.chat_ctx) == history_before
    assert _dump(ctx) == ctx_before
    folded = fold_system_messages(ctx)
    assert len(sent.items) < len(folded.items)
    assert agent.compactor.estimator.total(sent.items) <= 400
    # the system prompt is kept whole, and the history resumes at a user message
    assert _wire(llm.ChatContext(sent.items[:1])) == _wire(llm.ChatContext(folded.items[:1]))
    assert sent.items[1].role == "user"
    # the newest items are the request's newest items
    assert [i.id for i in sent.items[-5:]] == [i.id for i in folded.items[-5:]]
    calls = {i.call_id for i in sent.items if isinstance(i, llm.FunctionCall)}
    outputs = {i.call_id for i in sent.items if isinstance(i, llm.FunctionCallOutput)}
    assert calls == outputs


def test_backstop_stays_under_the_cap_turn_after_turn() -> None:
    """The usage of a capped turn calibrates against what was sent, not the untrimmed history:
    otherwise the ratio drifts low each turn and the cap overshoots more each time."""
    from happy_voice.compaction import TokenEstimator

    cap = 1000
    true = TokenEstimator(0.5)  # what the server counts
    ctx = _history(60)
    settings = _compaction_settings(
        VOICE_COMPACT_KEEP="10", VOICE_COMPACT_TRIGGER="200", VOICE_CONTEXT_HARD_CAP=str(cap)
    )
    agent = _assistant(settings, ctx, compactor=True, enabled=False)
    agent.compactor.estimator.tokens_per_char = 0.5
    assert true.total(fold_system_messages(ctx).items) > 3 * cap
    sent_tokens = []
    for _ in range(6):
        (sent,) = _run_llm_node(agent, ctx)
        real = true.total(sent.items)
        sent_tokens.append(real)
        agent.compactor.on_llm_usage(real, 0)
    # The calibration is unbiased now (template tags taken off), so the estimate only errs by
    # the per-item rounding of this test's token counts: within a token or two of the cap, and
    # not drifting from one turn to the next.
    assert max(sent_tokens) <= cap * 1.01, sent_tokens
    assert sent_tokens[-1] <= sent_tokens[1], sent_tokens
    assert agent.compactor.estimator.tokens_per_char >= 0.49


def _make_compactor(agent, summarizer, *, quiet=None, lock=None, warm=None, keep=150, trigger=400, **kw):
    from happy_voice.compaction import Compactor

    warmed: list = []

    async def default_warm(ctx, tools) -> bool:
        warmed.append((ctx, tools))
        return True

    if quiet is None:
        quiet = asyncio.Event()
        quiet.set()
    c = Compactor(
        agent=lambda: agent,
        summarizer=summarizer,
        warm=warm or default_warm,
        lock=lock or asyncio.Lock(),
        quiet=quiet,
        trigger=trigger,
        keep=keep,
        summary_tokens=kw.pop("summary_tokens", 20),
        estimator=_estimator(),
        **kw,
    )
    c.warmed = warmed
    return c


SUMMARY = "The user is refactoring auth in sess_1; tests pass."


def test_compaction_swaps_the_head_for_one_summary_and_keeps_the_tail() -> None:
    from happy_voice.compaction import INSTRUCTIONS_MESSAGE_ID, SUMMARY_PREFIX

    async def run():
        agent = _agent(_history(30))
        before = list(agent.chat_ctx.items)
        model = _FakeLLM(text=SUMMARY)
        swapped: list = []
        c = _make_compactor(agent, model, on_swapped=lambda: swapped.append(1))
        assert await c.compact_once(5000) is True
        return agent, before, model, c, swapped

    agent, before, model, c, swapped = asyncio.run(run())
    after = agent.chat_ctx.items
    assert after[0].id == INSTRUCTIONS_MESSAGE_ID and after[0].text_content == "instructions"
    assert after[1].role == "system" and after[1].text_content == SUMMARY_PREFIX + SUMMARY
    tail = after[2:]
    # the tail is the old history's last items, untouched and in order
    assert [i.id for i in tail] == [i.id for i in before[-len(tail) :]]
    assert _estimator().total(tail) >= 150
    assert len(after) < len(before)
    # still ordered by creation time, which later inserts rely on
    assert [i.created_at for i in after[1:]] == sorted(i.created_at for i in after[1:])
    assert swapped == [1]
    # the warm-up was of exactly what the next turn sends
    ((warm_ctx, warm_tools),) = c.warmed
    assert _wire(warm_ctx) == _wire(fold_system_messages(agent.chat_ctx))
    assert [t.info.name for t in warm_tools] == ["ping"]
    # one summary request, text only
    assert len(model.requests) == 1
    assert model.kwargs[0]["tool_choice"] == "none"


def test_summary_request_has_the_turn_request_as_its_prefix() -> None:
    from happy_voice.compaction import SUMMARY_INSTRUCTION, split_history

    async def run():
        agent = _agent(_history(30))
        turn_request = fold_system_messages(agent.chat_ctx)
        turn_tools = llm.ToolContext(agent.tools).flatten()
        model = _FakeLLM(text=SUMMARY)
        c = _make_compactor(agent, model)
        split = split_history(agent.chat_ctx.items, c.keep, c.estimator)
        await c.compact_once(5000)
        return turn_request, turn_tools, model, split

    turn_request, turn_tools, model, split = asyncio.run(run())
    ((request, tools),) = model.requests
    *conversation, instruction = request.items
    assert instruction.role == "user" and instruction.text_content == SUMMARY_INSTRUCTION
    # byte-identical to the turn's own request up to the split, with the same tools
    assert _wire(llm.ChatContext(conversation)) == _wire(
        llm.ChatContext(turn_request.items[: len(conversation)])
    )
    assert turn_request.items[len(conversation)].id == split.tail[0].id
    assert [t.info.name for t in tools] == [t.info.name for t in turn_tools]


def test_items_added_during_the_summary_survive_the_swap() -> None:
    async def run():
        agent = _agent(_history(30))
        model = _FakeLLM(text=SUMMARY, delay=0.002)
        c = _make_compactor(agent, model)
        task = asyncio.create_task(c.compact_once(5000))
        await asyncio.sleep(0.01)
        assert model.requests, "the summary is being written"
        # what handle_inbox does with a context update, and what a turn does with its reply
        new_ctx = agent.chat_ctx.copy()
        update = new_ctx.add_message(role="system", content="Session became focused: sess_2")
        reply = new_ctx.add_message(role="assistant", content="Switched to sess_2.")
        await agent.update_chat_ctx(new_ctx)
        assert await task is True
        return agent, update, reply

    agent, update, reply = asyncio.run(run())
    ids = [i.id for i in agent.chat_ctx.items]
    assert ids[-2:] == [update.id, reply.id]
    assert agent.chat_ctx.items[1].text_content.endswith(SUMMARY)


def test_a_failed_or_empty_summary_or_warm_up_leaves_the_history_untouched() -> None:
    async def failing_warm(ctx, tools) -> bool:
        return False

    cases = (
        dict(summarizer=_FakeLLM(fail=True)),
        dict(summarizer=_FakeLLM(text="")),
        dict(summarizer=_FakeLLM(text="   \n ")),
        dict(summarizer=_FakeLLM(text=SUMMARY), warm=failing_warm),
    )
    for case in cases:

        async def run():
            agent = _agent(_history(30))
            before = _dump(agent.chat_ctx)
            c = _make_compactor(agent, case.pop("summarizer"), **case)
            ok = await c.compact_once(5000)
            return agent, before, ok

        agent, before, ok = asyncio.run(run())
        assert ok is False
        assert _dump(agent.chat_ctx) == before


def test_a_failure_backs_off_and_one_compaction_runs_at_a_time() -> None:
    now = [100.0]

    async def run():
        agent = _agent(_history(30))
        model = _FakeLLM(fail=True, delay=0.001)
        c = _make_compactor(agent, model, clock=lambda: now[0])
        c.on_llm_usage(100, 0)  # below the trigger
        assert c._task is None
        c.on_llm_usage(5000, 0)
        first = c._task
        c.on_llm_usage(5000, 0)  # one at a time
        assert c._task is first
        await first
        c.on_llm_usage(5000, 0)  # backing off: 30 s after the first failure
        assert c._task is first
        now[0] += 31
        c.on_llm_usage(5000, 0)
        second = c._task
        assert second is not first
        await second
        now[0] += 31  # the second failure doubled the wait to 60 s
        c.on_llm_usage(5000, 0)
        assert c._task is second
        now[0] += 30
        c.on_llm_usage(5000, 0)
        assert c._task is not second
        await c._task
        return model, c

    model, c = asyncio.run(run())
    assert len(model.requests) == 3
    assert c._failures == 3


def test_compaction_off_never_schedules() -> None:
    async def run():
        agent = _agent(_history(30))
        model = _FakeLLM(text=SUMMARY)
        c = _make_compactor(agent, model, enabled=False)
        c.on_llm_usage(10**6, 0)
        await asyncio.sleep(0.01)
        return c, model

    c, model = asyncio.run(run())
    assert c._task is None and model.requests == []


def test_the_swap_waits_for_quiet() -> None:
    async def run():
        agent = _agent(_history(30))
        before = _dump(agent.chat_ctx)
        quiet = asyncio.Event()
        quiet.set()
        model = _FakeLLM(text=SUMMARY, delay=0.001)
        warm_started = asyncio.Event()

        async def warm(ctx, tools) -> bool:
            # the user starts talking while the compacted history is prefilled
            quiet.clear()
            warm_started.set()
            return True

        c = _make_compactor(agent, model, quiet=quiet, warm=warm)
        task = asyncio.create_task(c.compact_once(5000))
        await warm_started.wait()
        await asyncio.sleep(0.05)
        unchanged_while_busy = _dump(agent.chat_ctx) == before
        quiet.set()
        assert await task is True
        return agent, before, unchanged_while_busy

    agent, before, unchanged_while_busy = asyncio.run(run())
    assert unchanged_while_busy
    assert _dump(agent.chat_ctx) != before


def test_the_swap_also_waits_for_the_context_lock() -> None:
    async def run():
        agent = _agent(_history(30))
        lock = asyncio.Lock()
        c = _make_compactor(agent, _FakeLLM(text=SUMMARY), lock=lock)
        await lock.acquire()
        task = asyncio.create_task(c.compact_once(5000))
        await asyncio.sleep(0.2)
        held = not task.done()
        lock.release()
        return held, await task

    held, ok = asyncio.run(run())
    assert held and ok


def test_the_swap_emits_nothing_and_the_summary_reaches_neither_speech_nor_transcript() -> None:
    """Swaps through LiveKit's own AgentSession and AgentActivity: the session's history (the
    transcript) and its events are untouched, and the summary is a system message only."""
    from livekit.agents import AgentSession
    from livekit.agents.voice.agent_activity import AgentActivity

    async def run():
        agent = _agent(_history(30))
        session = AgentSession()
        for item in _history(30).items:  # the transcript as the session recorded it
            session._chat_ctx.items.append(item.model_copy())
        transcript_before = _dump(session.history)
        emitted: list[str] = []
        real_emit = session.emit

        def emit(event, *args):
            emitted.append(event)
            return real_emit(event, *args)

        session.emit = emit
        activity = AgentActivity(agent, session)
        agent._activity = activity
        session._activity = activity
        speech_before = (activity._current_speech, list(activity._speech_q))
        before = _dump(agent.chat_ctx)
        c = _make_compactor(agent, _FakeLLM(text=SUMMARY))
        try:
            assert await c.compact_once(5000) is True
        finally:
            agent._activity = None
            session._activity = None
        speech_after = (activity._current_speech, list(activity._speech_q))
        return agent, session, before, transcript_before, emitted, speech_before, speech_after

    agent, session, before, transcript_before, emitted, speech_before, speech_after = asyncio.run(run())
    assert _dump(agent.chat_ctx) != before  # it did swap, through the activity
    assert emitted == []
    assert _dump(session.history) == transcript_before
    assert not any(SUMMARY in (getattr(i, "text_content", None) or "") for i in session.history.items)
    assert speech_after == speech_before == (None, [])
    summaries = [
        i for i in agent.chat_ctx.items if isinstance(i, llm.ChatMessage) and SUMMARY in (i.text_content or "")
    ]
    # only in the agent's history, as a system message: never an assistant line to speak
    assert [m.role for m in summaries] == ["system"]


def test_a_second_compaction_rolls_the_first_summary_forward() -> None:
    from happy_voice.compaction import SUMMARY_PREFIX

    async def run():
        agent = _agent(_history(30))
        c = _make_compactor(agent, _FakeLLM(text=SUMMARY))
        assert await c.compact_once(5000) is True
        # the call goes on
        new_ctx = agent.chat_ctx.copy()
        for item in _history(30).items[3:]:
            new_ctx.items.append(
                item.model_copy(update={"id": "late_" + item.id, "created_at": item.created_at + 10**6})
            )
        await agent.update_chat_ctx(new_ctx)
        second = _FakeLLM(text="Second summary.")
        c._summarizer = second
        assert await c.compact_once(5000) is True
        return agent, second

    agent, second = asyncio.run(run())
    ((request, _),) = second.requests
    # the first summary went into the second one's input (folded into the system prompt)
    assert SUMMARY in request.items[0].text_content
    summaries = [
        i.text_content
        for i in agent.chat_ctx.items
        if isinstance(i, llm.ChatMessage) and (i.text_content or "").startswith(SUMMARY_PREFIX)
    ]
    assert summaries == [SUMMARY_PREFIX + "Second summary."]


def test_one_shot_warm_shares_the_turn_bookkeeping() -> None:
    async def run():
        model = _FakeLLM(delay=0.05)
        warmer = PrefixWarmer(model, lambda: ("snapshot", []), debounce=0)
        # waits for a turn in progress, then prefills
        await warmer.begin_turn()
        task = asyncio.create_task(warmer.warm("compacted", ["tool"]))
        await asyncio.sleep(0.02)
        sent_during_turn = len(model.requests)
        warmer.end_turn()
        await asyncio.sleep(0.01)
        # a turn that starts while it is in flight cancels it at once instead of waiting
        t0 = time.monotonic()
        await warmer.begin_turn()
        turn_waited = time.monotonic() - t0
        warmer.end_turn()
        ok = await task
        await warmer.aclose()
        return model, sent_during_turn, turn_waited, ok, warmer

    model, sent_during_turn, turn_waited, ok, warmer = asyncio.run(run())
    assert sent_during_turn == 0
    assert turn_waited < 0.02
    assert ok is True
    # sent, given way to the turn, sent again
    assert [r[0] for r in model.requests] == ["compacted", "compacted"]
    assert model.chunks_read == 1
    # a one-shot does not skew the estimate begin_turn() uses for scheduled warm-ups
    assert warmer._durations == [] and warmer.completed == 0


def test_one_shot_warm_failure_is_false_not_raised() -> None:
    async def run():
        warmer = PrefixWarmer(_FakeLLM(fail=True), lambda: ("x", []), debounce=0)
        ok = await warmer.warm("compacted", [])
        await warmer.aclose()
        return ok

    assert asyncio.run(run()) is False


def test_a_turn_does_not_cancel_the_summary_in_flight() -> None:
    from happy_voice.compaction import SUMMARY_PREFIX

    async def run():
        agent = _agent(_history(30))
        before = _dump(agent.chat_ctx)
        prefill = _FakeLLM()
        warmer = PrefixWarmer(prefill, lambda: ("snapshot", []), debounce=0)
        # ~0.5 s to write, so a turn lands in the middle of it
        model = _FakeLLM(text=SUMMARY, delay=0.01)
        c = _make_compactor(agent, model, warm=warmer.warm, turn_idle=warmer.wait_idle)
        task = asyncio.create_task(c.compact_once(5000))
        await asyncio.sleep(0.1)
        assert len(model.requests) == 1
        t0 = time.monotonic()
        await warmer.begin_turn()
        turn_waited = time.monotonic() - t0
        await asyncio.sleep(0.05)
        seen = {
            # still being written: not closed, and not sent a second time
            "running": model.closed_streams == 0 and len(model.requests) == 1,
        }
        # the turn outlasts the summary; it finishes during the turn and waits to be swapped
        while model.closed_streams == 0:
            await asyncio.sleep(0.01)
        await asyncio.sleep(0.05)
        seen["finished"] = model.chunks_read == len(SUMMARY)
        seen["held_for_the_turn"] = not task.done() and _dump(agent.chat_ctx) == before
        seen["no_prefill_during_the_turn"] = prefill.requests == []
        warmer.end_turn()
        ok = await task
        await warmer.aclose()
        return agent, model, prefill, c, turn_waited, seen, ok

    agent, model, prefill, c, turn_waited, seen, ok = asyncio.run(run())
    assert turn_waited < 0.02
    assert seen == {
        "running": True,
        "finished": True,
        "held_for_the_turn": True,
        "no_prefill_during_the_turn": True,
    }
    assert ok is True
    assert len(model.requests) == 1 and model.closed_streams == 1 and c._failures == 0
    assert len(prefill.requests) == 1
    assert agent.chat_ctx.items[1].text_content == SUMMARY_PREFIX + SUMMARY
    assert c.compactions == 1 and c._pending is None


def test_a_prefill_that_keeps_giving_way_keeps_the_summary_for_the_next_attempt() -> None:
    from happy_voice.compaction import SUMMARY_ID_PREFIX, SUMMARY_PREFIX

    now = [100.0]

    async def run():
        agent = _agent(_history(30))
        before = _dump(agent.chat_ctx)
        model = _FakeLLM(text=SUMMARY)
        prefills: list = []
        gets_through = [False]

        async def warm(ctx, tools) -> bool:
            # what PrefixWarmer.warm returns after giving way to a turn on every attempt
            prefills.append(ctx)
            return gets_through[0]

        c = _make_compactor(agent, model, warm=warm, clock=lambda: now[0])
        c.on_llm_usage(5000, 0)
        await c._task
        seen = {
            "failures": c._failures,
            "unchanged": _dump(agent.chat_ctx) == before,
            "kept": c._pending is not None and c._pending.text == SUMMARY,
            "compactions": c.compactions,
        }
        # the call goes on, then the next attempt after the backoff
        new_ctx = agent.chat_ctx.copy()
        new_ctx.add_message(role="user", content="and the tests?")
        new_ctx.add_message(role="assistant", content="They pass.")
        await agent.update_chat_ctx(new_ctx)
        gets_through[0] = True
        now[0] += 31
        c.on_llm_usage(5000, 0)
        await c._task
        return agent, model, prefills, c, seen

    agent, model, prefills, c, seen = asyncio.run(run())
    assert seen == {"failures": 1, "unchanged": True, "kept": True, "compactions": 1}
    # no second summary request: the kept one was reused and swapped in
    assert len(model.requests) == 1
    assert len(prefills) == 2
    assert c._failures == 0 and c._pending is None
    summary = agent.chat_ctx.items[1]
    assert summary.text_content == SUMMARY_PREFIX + SUMMARY
    assert summary.id == f"{SUMMARY_ID_PREFIX}1" and c.compactions == 1
    # what arrived in between is kept
    assert [i.text_content for i in agent.chat_ctx.items[-2:]] == ["and the tests?", "They pass."]


def test_a_kept_summary_is_dropped_once_the_history_is_rewritten() -> None:
    async def run():
        agent = _agent(_history(30))
        model = _FakeLLM(text=SUMMARY)
        gets_through = [False]

        async def warm(ctx, tools) -> bool:
            return gets_through[0]

        c = _make_compactor(agent, model, warm=warm)
        assert await c.compact_once(5000) is False
        kept = c._pending
        # an item the summary covered is gone: the summary no longer describes this history
        gone = next(iter(kept.head_ids))
        await agent.update_chat_ctx(
            llm.ChatContext([i for i in agent.chat_ctx.items if i.id != gone])
        )
        gets_through[0] = True
        assert await c.compact_once(5000) is True
        return model, c, kept

    model, c, kept = asyncio.run(run())
    assert len(model.requests) == 2
    assert c._pending is None and c.compactions == 2


def test_the_newest_keep_tokens_survive_the_swap_verbatim() -> None:
    from happy_voice.compaction import KEEP_MARGIN, split_history

    async def run():
        agent = _agent(_history(30))
        model = _FakeLLM(text=SUMMARY)
        c = _make_compactor(agent, model)
        split = split_history(agent.chat_ctx.items, c.keep, c.estimator)
        tail = [i.model_dump(mode="json") for i in split.tail]
        assert await c.compact_once(5000) is True
        return agent, c, split, tail

    agent, c, split, tail = asyncio.run(run())
    after = {i.id: i.model_dump(mode="json") for i in agent.chat_ctx.items}
    for item in tail:
        assert after.get(item["id"]) == item, item["id"]
    assert c.estimator.total(split.tail) >= c.keep * KEEP_MARGIN >= c.keep
    assert not (split.head_ids & set(after))


def test_a_tail_under_keep_is_never_summarized() -> None:
    import happy_voice.compaction as compaction

    async def run():
        agent = _agent(_history(30))
        before = _dump(agent.chat_ctx)
        model = _FakeLLM(text=SUMMARY)
        c = _make_compactor(agent, model)
        real = compaction.split_history

        def short_tail(items, keep_tokens, estimator):
            # a split whose tail came out short of keep, however that happened
            return real(items, keep_tokens // 3, estimator)

        compaction.split_history = short_tail
        try:
            ok = await c.compact_once(5000)
        finally:
            compaction.split_history = real
        return agent, before, model, ok

    agent, before, model, ok = asyncio.run(run())
    assert ok is False and model.requests == []
    assert _dump(agent.chat_ctx) == before


def test_closing_the_warmer_waits_for_a_one_shot_in_flight() -> None:
    async def run():
        model = _FakeLLM(delay=0.05)
        warmer = PrefixWarmer(model, lambda: ("snapshot", []), debounce=0)
        task = asyncio.create_task(warmer.warm("compacted", []))
        await asyncio.sleep(0.01)
        await warmer.aclose()
        # the stream was closed before the model was
        return model.closed_streams, model.closed, task

    closed_streams, closed, task = asyncio.run(run())
    assert closed_streams == 1 and closed


def test_the_swap_waits_out_the_end_of_a_user_turn_and_any_preemptive_reply() -> None:
    """VAD end of speech sets `quiet` before the user's turn completes, and a preemptive
    generation may be holding a copy of the history in that window: the swap must not land
    until the quiet has settled and no reply is in the making."""
    from types import SimpleNamespace

    async def run():
        agent = _agent(_history(30))
        before = _dump(agent.chat_ctx)
        warmer = PrefixWarmer(_FakeLLM(), lambda: ("snapshot", []), debounce=0)
        activity = SimpleNamespace(_preemptive_generation=None)
        session = SimpleNamespace(_activity=activity)
        quiet = asyncio.Event()
        quiet_since = [time.monotonic()]
        seen: dict = {}

        async def warm(ctx, tools) -> bool:
            # the user stops speaking: quiet again, and a preemptive reply starts on a copy
            quiet_since[0] = time.monotonic()
            quiet.set()
            activity._preemptive_generation = SimpleNamespace(chat_ctx=agent.chat_ctx.copy())
            return True

        from happy_voice.assistant import no_reply_pending

        c = _make_compactor(
            agent,
            _FakeLLM(text=SUMMARY),
            quiet=quiet,
            warm=warm,
            quiet_for=lambda: time.monotonic() - quiet_since[0],
            settle=0.2,
            no_reply_pending=lambda: no_reply_pending(session, warmer),
            turn_idle=warmer.wait_idle,
        )
        quiet.set()  # quiet long enough when the compaction starts
        quiet_since[0] -= 10
        task = asyncio.create_task(c.compact_once(5000))
        await asyncio.sleep(0.1)
        seen["inside_settle"] = _dump(agent.chat_ctx) == before
        await asyncio.sleep(0.3)
        # settled, but the preemptive reply is still pending
        seen["preemptive_pending"] = _dump(agent.chat_ctx) == before
        # the user's turn completes: LiveKit checks the copy against the history, then drops it
        preemptive = activity._preemptive_generation
        seen["preemptive_still_valid"] = preemptive.chat_ctx.is_equivalent(agent.chat_ctx)
        await warmer.begin_turn()  # the reply's request is in flight
        activity._preemptive_generation = None
        await asyncio.sleep(0.2)
        seen["turn_running"] = _dump(agent.chat_ctx) == before
        warmer.end_turn()
        assert await task is True
        await warmer.aclose()
        return agent, before, seen

    agent, before, seen = asyncio.run(run())
    assert seen == {
        "inside_settle": True,
        "preemptive_pending": True,
        "preemptive_still_valid": True,
        "turn_running": True,
    }
    assert _dump(agent.chat_ctx) != before


def test_no_reply_pending_reads_the_session_the_library_builds() -> None:
    """Pins the private attribute no_reply_pending() reads to LiveKit's own AgentActivity."""
    from types import SimpleNamespace

    from livekit.agents import AgentSession
    from livekit.agents.voice.agent_activity import AgentActivity

    from happy_voice.assistant import no_reply_pending

    async def run():
        warmer = PrefixWarmer(_FakeLLM(), lambda: ("snapshot", []), debounce=0)
        session = AgentSession()
        activity = AgentActivity(_agent(_history(2)), session)
        assert hasattr(activity, "_preemptive_generation")
        session._activity = activity
        results = [no_reply_pending(session, warmer)]
        activity._preemptive_generation = SimpleNamespace()
        results.append(no_reply_pending(session, warmer))
        activity._preemptive_generation = None
        await warmer.begin_turn()
        results.append(no_reply_pending(session, warmer))
        warmer.end_turn()
        results.append(no_reply_pending(session, warmer))
        # no activity yet (or a version without the attribute): nothing to wait for
        results.append(no_reply_pending(SimpleNamespace(), warmer))
        session._activity = None
        await warmer.aclose()
        return results

    assert asyncio.run(run()) == [True, False, False, True, True]


class _LogCapture:
    def __init__(self) -> None:
        import logging

        class _H(logging.Handler):
            def emit(inner, record: logging.LogRecord) -> None:
                self.messages.append(record.getMessage())

        self.messages: list[str] = []
        self._logger = logging.getLogger("happy-voice")
        self._handler = _H()

    def __enter__(self) -> "_LogCapture":
        import logging

        self._was = self._logger.level
        self._logger.setLevel(logging.INFO)
        self._logger.addHandler(self._handler)
        return self

    def __exit__(self, *exc) -> None:
        self._logger.removeHandler(self._handler)
        self._logger.setLevel(self._was)


def test_after_a_swap_no_compaction_starts_at_once_and_the_first_compacted_turn_is_logged() -> None:
    now = [100.0]

    async def run():
        agent = _agent(_history(30))
        model = _FakeLLM(text=SUMMARY)
        c = _make_compactor(agent, model, clock=lambda: now[0])
        c.on_llm_usage(5000, 0)
        await c._task
        assert c.compactions == 1
        with _LogCapture() as log:
            # usage of a request made before the swap: not the first compacted turn, and a
            # prompt still over the trigger does not start another compaction straight away
            c.on_llm_usage(5000, 0)
            assert c._task.done() and len(model.requests) == 1
            c.note_request(fold_system_messages(agent.chat_ctx))
            c.on_llm_usage(450, 400)
            c.note_request(fold_system_messages(agent.chat_ctx))
            c.on_llm_usage(460, 450)
        first = [m for m in log.messages if "first turn after the swap" in m]
        assert first == ["compaction: first turn after the swap: prompt=450 cached=400"]
        now[0] += 31
        c.on_llm_usage(5000, 0)
        assert not c._task.done()
        await c._task
        return model

    model = asyncio.run(run())
    assert len(model.requests) == 2


def test_a_head_too_small_for_the_trigger_is_not_summarized_over_and_over() -> None:
    async def run():
        agent = _agent(_history(30))
        before = _dump(agent.chat_ctx)
        model = _FakeLLM(text=SUMMARY)
        # the head is well over twice the summary, but frees little of the room under the trigger
        c = _make_compactor(agent, model, keep=150, trigger=20000, summary_tokens=20)
        from happy_voice.compaction import split_history

        split = split_history(agent.chat_ctx.items, c.keep, c.estimator)
        assert 2 * c.summary_tokens < split.head_tokens < (c.trigger - c.keep) // 2
        ok = await c.compact_once(20000)
        return agent, before, model, ok

    agent, before, model, ok = asyncio.run(run())
    assert ok is True and model.requests == []
    assert _dump(agent.chat_ctx) == before


def test_closing_the_compactor_stops_it_for_good() -> None:
    async def run():
        agent = _agent(_history(30))
        before = _dump(agent.chat_ctx)
        model = _FakeLLM(text=SUMMARY, delay=0.01)
        c = _make_compactor(agent, model)
        c.on_llm_usage(5000, 0)
        task = c._task
        await asyncio.sleep(0.05)
        await c.aclose()
        c.on_llm_usage(5000, 0)  # a usage report that arrives during shutdown
        return agent, before, model, c, task

    agent, before, model, c, task = asyncio.run(run())
    assert task.cancelled() and c._task is None and c.enabled is False
    assert model.closed and model.closed_streams == 1
    assert _dump(agent.chat_ctx) == before


def test_summary_request_sends_the_turn_tools_with_tool_choice_none() -> None:
    """Through the real openai plugin: the summary request carries the same tool schemas as a
    turn (so vLLM renders the same prompt prefix) and tool_choice "none" (so it writes text)."""
    from livekit.agents import APIConnectOptions

    from happy_voice.assistant import _make_llm, _make_summarizer_llm
    from happy_voice.compaction import summarize

    settings = _compaction_settings()

    async def capture(model, call) -> dict:
        seen: list[dict] = []

        async def create(**kwargs):
            seen.append(kwargs)
            raise RuntimeError("captured")

        model._client.chat.completions.create = create
        try:
            await call(model)
        except Exception:
            pass
        await model.aclose()
        return seen[0]

    async def run():
        ctx = _history(2)
        tools = llm.ToolContext([_ping_tool()]).flatten()
        no_retry = APIConnectOptions(max_retry=0)

        async def summary(model):
            await summarize(model, ctx, tools, timeout=5, conn_options=no_retry)

        async def turn(model):
            async with model.chat(chat_ctx=ctx, tools=tools, conn_options=no_retry) as stream:
                async for _ in stream:
                    pass

        return await capture(_make_summarizer_llm(settings), summary), await capture(_make_llm(settings), turn)

    summary_kwargs, turn_kwargs = asyncio.run(run())
    assert summary_kwargs["tool_choice"] == "none"
    assert summary_kwargs["tools"] and summary_kwargs["tools"] == turn_kwargs["tools"]
    assert summary_kwargs["messages"] == turn_kwargs["messages"]
    assert summary_kwargs["max_completion_tokens"] == settings.compact_summary_tokens


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
