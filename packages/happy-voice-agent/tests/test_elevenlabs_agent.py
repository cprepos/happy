"""Unit tests for the ElevenLabs-protocol worker (happy_voice/elevenlabs_agent.py); no services.

    python -m pytest tests/test_elevenlabs_agent.py
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import pytest  # noqa: E402
from livekit.agents import ToolError, llm  # noqa: E402

from happy_voice import elevenlabs_agent as ela  # noqa: E402
from happy_voice import elevenlabs_protocol as el  # noqa: E402
from happy_voice.context import fold_system_messages  # noqa: E402
from happy_voice.prompt import addressing_section  # noqa: E402
from test_units import (  # noqa: E402
    _FakeLLM,
    _compaction_settings,
    _estimator,
    _make_compactor,
    _run_llm_node,
    _wire,
)

APP_PROMPT = "You are the voice side.\n\nContext: {{initialConversationContext}} is given once."
INIT = el.InitiationData(
    prompt=APP_PROMPT,
    language="en",
    dynamic_variables={"initialConversationContext": '{"screen":"s1","conversations":["s1","s2"]}'},
    source="swift_sdk",
    version="3.4.0",
)


class _FakeParticipant:
    def __init__(self) -> None:
        self.sent: list[tuple[dict, dict]] = []

    async def publish_data(self, payload: bytes, **kwargs) -> None:
        self.sent.append((json.loads(payload), kwargs))


class _FakeRoom:
    def __init__(self) -> None:
        self.local_participant = _FakeParticipant()


def _call(identity: str = "user-1") -> ela.CallState:
    return ela.CallState(room=_FakeRoom(), user_identity=identity)  # type: ignore[arg-type]


def _el_agent(settings=None, chat_ctx=None, call=None):
    return ela.ElevenLabsAssistant(
        instructions="instructions",
        call=call or _call(),
        settings=settings or _compaction_settings(),
        chat_ctx=chat_ctx,
    )


# --- tools ---------------------------------------------------------------------------------


def test_tools_are_the_apps_four_plus_the_local_ones():
    from livekit.agents.llm import find_function_tools

    names = sorted(t.info.name for t in find_function_tools(ela.ElevenLabsAssistant))
    assert names == sorted(
        ["listConversations", "readConversation", "message", "navigate", "skip_turn", "end_call", "readAloud"]
    )


def test_client_tool_schemas_match_the_apps():
    required = {
        "listConversations": [],
        "readConversation": ["ref"],
        "message": ["text"],
        "navigate": ["to", "focusRevision"],
    }
    for schema in (ela.LIST_CONVERSATIONS_SCHEMA, ela.READ_CONVERSATION_SCHEMA, ela.MESSAGE_SCHEMA, ela.NAVIGATE_SCHEMA):
        params = schema["parameters"]
        assert params["type"] == "object"
        assert params["required"] == required[schema["name"]]
        assert set(params["required"]) <= set(params["properties"])
    assert ela.READ_CONVERSATION_SCHEMA["parameters"]["properties"]["words"]["type"] == "integer"
    assert ela.NAVIGATE_SCHEMA["parameters"]["properties"]["focusRevision"]["type"] == "integer"
    # context.py leaves skip_turn calls out of the history by this name
    assert ela.EL_SKIP_TURN_SCHEMA["name"] == "skip_turn"


def test_client_tool_round_trip():
    async def run():
        call = _call()
        agent = _el_agent(call=call)
        call.event_id = 4
        task = asyncio.create_task(agent._client_tool("navigate", {"to": "happy://home", "focusRevision": 3}))
        await asyncio.sleep(0.01)
        (event, kwargs), = call.room.local_participant.sent
        assert el.validate_agent_event(event) == []
        body = event["client_tool_call"]
        assert body["tool_name"] == "navigate" and body["event_id"] == 4 and body["expects_response"] is True
        assert kwargs == {"reliable": True, "destination_identities": ["user-1"]}
        call.pending_tools[body["tool_call_id"]].set_result(
            el.ClientEvent(type="client_tool_result", tool_call_id=body["tool_call_id"], result='{"ok":true}')
        )
        result = await task
        assert result == '{"ok":true}'
        assert call.pending_tools == {}
        assert call.tool_calls[0]["result"] == '{"ok":true}'

    asyncio.run(run())


def test_client_tool_error_and_timeout(monkeypatch):
    async def error():
        call = _call()
        agent = _el_agent(call=call)
        task = asyncio.create_task(agent._client_tool("message", {"text": "hi"}))
        await asyncio.sleep(0.01)
        tool_call_id = call.room.local_participant.sent[0][0]["client_tool_call"]["tool_call_id"]
        call.pending_tools[tool_call_id].set_result(
            el.ClientEvent(type="client_tool_result", tool_call_id=tool_call_id, result='{"ok":false}', is_error=True)
        )
        with pytest.raises(ToolError, match="ok"):
            await task

    async def timeout():
        agent = _el_agent()
        with pytest.raises(ToolError, match="in time"):
            await agent._client_tool("listConversations", {})

    async def no_app():
        agent = _el_agent(call=_call(identity=""))
        with pytest.raises(ToolError, match="not connected"):
            await agent._client_tool("listConversations", {})

    asyncio.run(error())
    monkeypatch.setattr(ela, "TOOL_TIMEOUT", 0.05)
    asyncio.run(timeout())
    asyncio.run(no_app())


class _EndSession:
    closed = False

    async def aclose(self):
        self.closed = True


class _EndCtx:
    def __init__(self):
        self.session = _EndSession()
        self.waited = False

    async def wait_for_playout(self):
        self.waited = True


def _said_goodbye() -> llm.ChatContext:
    ctx = llm.ChatContext.empty()
    ctx.add_message(role="user", content="That's all, bye!")
    ctx.add_message(role="assistant", content="Bye, talk soon.")
    return ctx


def test_end_call_after_a_goodbye_tells_the_sdk(monkeypatch):
    monkeypatch.setattr(ela, "END_CALL_GRACE", 0.01)

    async def run():
        call = _call()
        agent = _el_agent(call=call, chat_ctx=_said_goodbye())
        ctx = _EndCtx()
        assert await ela.ElevenLabsAssistant.end_call(agent, {}, ctx) is None
        # a second call in the same goodbye sends nothing more
        await ela.ElevenLabsAssistant.end_call(agent, {}, ctx)
        await asyncio.sleep(0.05)
        return call, ctx

    call, ctx = asyncio.run(run())
    assert ctx.waited
    (event, _), = call.room.local_participant.sent
    assert event["type"] == "agent_tool_response"
    assert event["agent_tool_response"]["tool_name"] == "end_call"
    assert el.validate_agent_event(event) == []
    assert ctx.session.closed


def test_end_call_without_a_goodbye_asks_for_one_first(monkeypatch):
    monkeypatch.setattr(ela, "END_CALL_GRACE", 0.01)
    monkeypatch.setattr(ela, "GOODBYE_TIMEOUT", 0.05)
    history = llm.ChatContext.empty()
    history.add_message(role="assistant", content="The cache task is still working.")
    history.add_message(role="user", content="That's all, bye!")

    async def run():
        call = _call()
        agent = _el_agent(call=call, chat_ctx=history)
        ctx = _EndCtx()
        reply = await ela.ElevenLabsAssistant.end_call(agent, {}, ctx)
        assert "goodbye" in reply.lower()
        assert call.goodbye_pending and call.room.local_participant.sent == []
        # no goodbye came (the reply was skipped): it hangs up anyway
        await asyncio.sleep(0.1)
        return call, ctx

    call, ctx = asyncio.run(run())
    (event, _), = call.room.local_participant.sent
    assert event["agent_tool_response"]["tool_name"] == "end_call"
    assert not call.goodbye_pending and ctx.session.closed


def test_said_since_last_user_turn():
    assert ela.said_since_last_user_turn(_said_goodbye().items)
    ctx = _said_goodbye()
    ctx.add_message(role="user", content="wait")
    assert not ela.said_since_last_user_turn(ctx.items)
    assert not ela.said_since_last_user_turn([])


# --- prompt and initial context -------------------------------------------------------------


def test_instructions_fill_the_variables_and_keep_the_happy_voice_layout():
    text = ela.build_el_instructions(INIT, name="Morgan")
    assert text.startswith("# Voice output")
    assert "{{" not in text and '"screen":"s1"' in text
    assert "# How you receive information" not in text  # the app prompt has its own rules
    assert text.index("You are the voice side") < text.index("# How updates reach you")
    assert addressing_section() in text
    assert text.rstrip().endswith("When the user addresses you by your name, answer them.")


def test_instructions_without_a_prompt_are_the_default_ones():
    from happy_voice.prompt import build_instructions

    assert ela.build_el_instructions(None) == build_instructions(app_system_prompt="", session_id=None, language="")


def test_initial_context_goes_in_once():
    # embedded through the variable: not repeated in the history
    assert ela.initial_history(INIT, ela.build_el_instructions(INIT)).items == []
    bare = el.InitiationData(prompt="No variable here.", dynamic_variables=dict(INIT.dynamic_variables))
    (msg,) = ela.initial_history(bare, ela.build_el_instructions(bare)).items
    assert msg.role == "system" and msg.text_content.startswith("Conversation history so far:\n")


# --- the request path and compaction ---------------------------------------------------------


def _el_history(turns: int, words: int = 40) -> llm.ChatContext:
    """A call as this worker builds it: instructions, then turns with client tool round trips,
    contextual updates (system messages) and [app] cues."""
    from happy_voice.compaction import INSTRUCTIONS_MESSAGE_ID

    t = 1000.0
    ctx = llm.ChatContext.empty()

    def at() -> float:
        nonlocal t
        t += 1.0
        return t

    ctx.add_message(role="system", content="instructions", id=INSTRUCTIONS_MESSAGE_ID, created_at=at())
    filler = " ".join(["word"] * words)
    for n in range(turns):
        ctx.add_message(role="user", content=f"question {n} {filler}", created_at=at())
        if n % 3 == 0:
            ctx.items.append(
                llm.FunctionCall(call_id=f"toolu_{n}", name="readConversation", arguments='{"ref":"s1"}', created_at=at())
            )
            ctx.items.append(
                llm.FunctionCallOutput(
                    call_id=f"toolu_{n}", name="readConversation", output=json.dumps({"turns": [filler]}),
                    is_error=False, created_at=at(),
                )
            )
        ctx.add_message(role="assistant", content=f"answer {n} {filler}", created_at=at())
        if n % 2 == 1:
            ctx.add_message(role="system", content=json.dumps({"event": "focus", "ref": "s1", "n": n}), created_at=at())
        if n % 5 == 4:
            ctx.add_message(role="user", content='[app] {"event":"silence","endsIn":"30s"}', created_at=at())
    return ctx


def test_el_request_is_the_happy_voice_request_below_the_trigger():
    ctx = _el_history(10)
    agent = _el_agent(chat_ctx=ctx)
    (sent,) = _run_llm_node(agent, ctx)
    assert _wire(sent) == _wire(fold_system_messages(ctx))


def test_el_request_is_capped_over_the_hard_cap():
    from happy_voice.compaction import Compactor

    settings = _compaction_settings(VOICE_COMPACT_KEEP="10", VOICE_COMPACT_TRIGGER="200", VOICE_CONTEXT_HARD_CAP="1000")
    ctx = _el_history(60)
    agent = _el_agent(settings=settings, chat_ctx=ctx)
    agent.compactor = Compactor(
        agent=lambda: agent, summarizer=_FakeLLM(text="never"), warm=None, lock=asyncio.Lock(),
        quiet=asyncio.Event(), trigger=settings.compact_trigger, keep=settings.compact_keep,
        summary_tokens=settings.compact_summary_tokens, enabled=False,
    )
    (sent,) = _run_llm_node(agent, ctx)
    assert agent.compactor.estimator.total(sent.items) <= 1000 * 1.05
    assert len(sent.items) < len(fold_system_messages(ctx).items)


def test_el_compaction_summarizes_and_swaps_without_dropping_a_turn():
    from happy_voice.compaction import INSTRUCTIONS_MESSAGE_ID, SUMMARY_PREFIX, SUMMARY_INSTRUCTION

    summary = "The person read s1 and was told about the cache race; nothing was sent."

    async def run():
        agent = _el_agent(chat_ctx=_el_history(30))
        before = list(agent.chat_ctx.items)
        model = _FakeLLM(text=summary, delay=0.001)
        c = _make_compactor(agent, model)
        agent.compactor = c
        task = asyncio.create_task(c.compact_once(5000))
        await asyncio.sleep(0.01)
        # a turn and a contextual update land while the summary is being written
        new_ctx = agent.chat_ctx.copy()
        late_user = new_ctx.add_message(role="user", content="and what about s2?")
        late_update = new_ctx.add_message(role="system", content='{"event":"assistant_text","ref":"s2"}')
        late_reply = new_ctx.add_message(role="assistant", content="s2 is still building.")
        await agent.update_chat_ctx(new_ctx)
        assert await task is True
        return agent, before, model, c, (late_user, late_update, late_reply)

    agent, before, model, c, late = asyncio.run(run())
    after = agent.chat_ctx.items
    assert after[0].id == INSTRUCTIONS_MESSAGE_ID
    assert after[1].role == "system" and after[1].text_content == SUMMARY_PREFIX + summary
    # the kept tail is the old history's end, in order, then everything that came in meanwhile
    tail = after[2:-3]
    assert [i.id for i in tail] == [i.id for i in before[-len(tail):]]
    assert [i.id for i in after[-3:]] == [i.id for i in late]
    assert len(after) < len(before)
    # no tool call lost its output, nor an output its call
    calls = {i.call_id for i in after if isinstance(i, llm.FunctionCall)}
    outputs = {i.call_id for i in after if isinstance(i, llm.FunctionCallOutput)}
    assert calls == outputs
    # every user turn is either kept or summarized: the kept ones are a suffix of the turns
    users_before = [i.id for i in before if isinstance(i, llm.ChatMessage) and i.role == "user"]
    kept = [i.id for i in tail if isinstance(i, llm.ChatMessage) and i.role == "user"]
    assert kept == users_before[len(users_before) - len(kept):]
    # the summary request carries the worker's own tools, and the warm-up is the next request
    ((request, tools),) = model.requests
    assert request.items[-1].text_content == SUMMARY_INSTRUCTION
    assert "readConversation" in {t.info.name for t in tools}
    ((warm_ctx, _),) = c.warmed
    assert _wire(warm_ctx) == _wire(fold_system_messages(agent.chat_ctx))
    # and the next request sends the summary first, then the kept turns
    (sent,) = _run_llm_node(agent, agent.chat_ctx)
    assert sent.items[0].text_content.startswith("instructions")
    assert SUMMARY_PREFIX + summary in sent.items[0].text_content
