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
from happy_voice.context import fold_system_messages, focused_session_from  # noqa: E402
from happy_voice.prompt import (  # noqa: E402
    BASE_PROMPT,
    CONTEXT_PREFIX,
    PERMISSION_SCHEMA,
    SEND_MESSAGE_SCHEMA,
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


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
