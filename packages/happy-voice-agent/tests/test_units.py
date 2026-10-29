"""Unit tests for the pure helpers (no services needed).

    python -m pytest tests/test_units.py      or      python tests/test_units.py
"""

from __future__ import annotations

import asyncio
import os
import sys
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
from happy_voice.names import voice_name  # noqa: E402
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
        return object()

    async def aclose(self) -> None:
        self._owner.closed_streams += 1


class _FakeLLM:
    def __init__(self, delay: float = 0.0, fail: bool = False) -> None:
        self.delay = delay
        self.fail = fail
        self.requests: list[tuple[object, object]] = []
        self.kwargs: list[dict] = []
        self.chunks_read = 0
        self.closed_streams = 0
        self.closed = False

    def chat(self, *, chat_ctx, tools, **kwargs):
        self.requests.append((chat_ctx, tools))
        self.kwargs.append(kwargs)
        return _FakeStream(self, chunks=50)

    async def aclose(self) -> None:
        self.closed = True


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
    # agentgateway's MoE tier by name, which fails over to dense on its own. Not the virtual
    # `coder`, which routes per request and so warms the tier the turn may not use, and not
    # 8899: that is coder-tool-proxy, which sets stream=False upstream, so a voice turn would
    # wait for the whole answer before the first word is spoken. See happy_voice/config.py.
    assert (s.llm_base_url, s.llm_model) == ("http://127.0.0.1:8903/v1", "coder-moe")
    assert s.llm_timeout == 60.0
    assert s.llm_max_retry == 0
    assert s.max_endpointing_delay == 1.5
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
    assert th["endpointing"] == {"min_delay": 0.4, "max_delay": 1.5}


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


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
