"""Unit tests for the ElevenLabs SDK 3.4.0 data-channel codec (no services needed).

    python -m pytest tests/test_elevenlabs_protocol.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402

from happy_voice import elevenlabs_protocol as p  # noqa: E402


def roundtrip(event: dict) -> dict:
    return json.loads(p.encode(event))


# --- builders produce what EventParser.swift requires ---------------------------------------


def test_conversation_initiation_metadata_shape():
    ev = roundtrip(p.conversation_initiation_metadata("conv_1"))
    assert ev["type"] == "conversation_initiation_metadata"
    body = ev["conversation_initiation_metadata_event"]
    assert body == {
        "conversation_id": "conv_1",
        "agent_output_audio_format": "pcm_48000",
        "user_input_audio_format": "pcm_48000",
    }


def test_user_transcript_shape():
    ev = roundtrip(p.user_transcript("hello", 3))
    assert ev == {"type": "user_transcript", "user_transcription_event": {"user_transcript": "hello", "event_id": 3}}


def test_agent_response_shape():
    ev = roundtrip(p.agent_response("hi", 3, "r1"))
    assert ev["agent_response_event"] == {"agent_response": "hi", "event_id": 3, "response_id": "r1"}


def test_agent_response_correction_shape():
    ev = roundtrip(p.agent_response_correction("a long reply", "a long", 4, "r2"))
    assert ev["agent_response_correction_event"] == {
        "original_agent_response": "a long reply",
        "corrected_agent_response": "a long",
        "event_id": 4,
        "response_id": "r2",
    }


def test_interruption_shape():
    assert roundtrip(p.interruption(7)) == {"type": "interruption", "interruption_event": {"event_id": 7}}


def test_vad_score_is_a_double():
    ev = roundtrip(p.vad_score(1))
    assert ev["vad_score_event"]["vad_score"] == 1.0
    assert isinstance(ev["vad_score_event"]["vad_score"], float)


def test_ping_with_and_without_ping_ms():
    assert roundtrip(p.ping(1)) == {"type": "ping", "ping_event": {"event_id": 1}}
    assert roundtrip(p.ping(2, 35)) == {"type": "ping", "ping_event": {"event_id": 2, "ping_ms": 35}}


def test_client_tool_call_shape():
    ev = roundtrip(p.client_tool_call("navigate", "tc_1", {"to": "happy://home", "focusRevision": 3}, 5))
    assert ev["client_tool_call"] == {
        "tool_name": "navigate",
        "tool_call_id": "tc_1",
        "parameters": {"to": "happy://home", "focusRevision": 3},
        "event_id": 5,
        "expects_response": True,
    }


def test_agent_tool_request_and_response_shape():
    req = roundtrip(p.agent_tool_request("end_call", "tc_2", 6))
    assert req["agent_tool_request"] == {
        "tool_name": "end_call",
        "tool_call_id": "tc_2",
        "tool_type": "system",
        "event_id": 6,
    }
    resp = roundtrip(p.agent_tool_response("end_call", "tc_2", 6))
    assert resp["agent_tool_response"] == {
        "tool_name": "end_call",
        "tool_call_id": "tc_2",
        "tool_type": "system",
        "is_error": False,
        "event_id": 6,
    }


def test_client_error_shape():
    ev = roundtrip(p.client_error("boom"))
    assert ev == {"type": "client_error", "error_event": {"code": 1011, "message": "boom"}}


def test_tentative_user_transcript_shape():
    ev = roundtrip(p.tentative_user_transcript("hel", 1))
    assert ev["tentative_user_transcription_event"] == {"user_transcript": "hel", "event_id": 1}


def test_encode_is_compact_utf8():
    raw = p.encode(p.agent_response("café", 1, "r"))
    assert "café".encode() in raw
    assert b" " not in raw.replace("café".encode(), b"")


# --- the validator applies the parser's rules ------------------------------------------------


def test_validator_rejects_unknown_type():
    assert p.validate_agent_event({"type": "speech_started"}) == ["unknown event type 'speech_started'"]


def test_validator_rejects_missing_envelope_and_fields():
    assert p.validate_agent_event({"type": "interruption"})
    assert p.validate_agent_event({"type": "interruption", "interruption_event": {}})
    errs = p.validate_agent_event({"type": "agent_response", "agent_response_event": {"agent_response": "x", "event_id": 1}})
    assert errs == ["agent_response: missing agent_response_event.response_id"]


def test_validator_is_strict_about_numbers_and_bools():
    # Swift would bridge these through NSNumber; the worker must not rely on that
    assert p.validate_agent_event({"type": "interruption", "interruption_event": {"event_id": True}})
    assert p.validate_agent_event({"type": "interruption", "interruption_event": {"event_id": "1"}})
    assert p.validate_agent_event({"type": "interruption", "interruption_event": {"event_id": 1.0}})
    bad_bool = p.client_tool_call("x", "y", {}, 1)
    bad_bool["client_tool_call"]["expects_response"] = 1
    assert p.validate_agent_event(bad_bool)
    # a Double accepts an integer value, as `as? Double` does
    assert p.validate_agent_event({"type": "vad_score", "vad_score_event": {"vad_score": 1}}) == []
    assert p.validate_agent_event({"type": "vad_score", "vad_score_event": {"vad_score": False}})


def test_validator_optional_ping_ms():
    assert p.validate_agent_event({"type": "ping", "ping_event": {"event_id": 1}}) == []
    assert p.validate_agent_event({"type": "ping", "ping_event": {"event_id": 1, "ping_ms": "3"}})


def test_validator_parameters_must_be_object():
    ev = p.client_tool_call("x", "y", {}, 1)
    ev["client_tool_call"]["parameters"] = "{}"
    assert p.validate_agent_event(ev)


def test_validator_client_error_without_body_parses():
    assert p.validate_agent_event({"type": "client_error"}) == []


def test_encode_refuses_invalid():
    with pytest.raises(ValueError):
        p.encode({"type": "agent_response", "agent_response_event": {}})


def test_every_builder_is_valid():
    events = [
        p.conversation_initiation_metadata("c"),
        p.user_transcript("u", 1),
        p.tentative_user_transcript("u", 1),
        p.agent_response("a", 1, "r"),
        p.agent_response_correction("a", "b", 1, "r"),
        p.interruption(1),
        p.vad_score(0.0),
        p.ping(1, 0),
        p.client_tool_call("t", "id", {"a": 1}, 1, expects_response=False),
        p.agent_tool_request("t", "id", 1),
        p.agent_tool_response("t", "id", 1, is_error=True, tool_type="client"),
        p.client_error("m", error_name="n"),
    ]
    for ev in events:
        assert p.validate_agent_event(ev) == [], ev
        assert ev["type"] in p.KNOWN_AGENT_EVENTS


# --- client events, as EventSerializer.swift writes them ------------------------------------

INIT = {
    "type": "conversation_initiation_client_data",
    "conversation_config_override": {
        "agent": {"prompt": {"prompt": "You are {{who}}. Context: {{initialConversationContext}}"}, "language": "en"},
        "tts": {"voice_id": "am_michael", "speed": 1.1},
        "conversation": {"text_only": False},
    },
    "custom_llm_extra_body": {},
    "dynamic_variables": {"initialConversationContext": "the time is noon", "who": "a voice"},
    "source_info": {"source": "swift_sdk", "version": "3.4.0"},
    "user_id": "u_1",
}


def test_parse_initiation():
    ev = p.parse_client_event(json.dumps(INIT).encode())
    assert ev.type == "conversation_initiation_client_data"
    init = ev.initiation
    assert init is not None
    assert init.prompt.startswith("You are {{who}}")
    assert init.language == "en"
    assert init.first_message == ""
    assert init.voice_id == "am_michael"
    assert init.speed == 1.1
    assert init.dynamic_variables["who"] == "a voice"
    assert (init.source, init.version, init.user_id) == ("swift_sdk", "3.4.0", "u_1")


def test_parse_initiation_tolerates_missing_parts():
    ev = p.parse_client_event(b'{"type":"conversation_initiation_client_data"}')
    assert ev.initiation is not None
    assert ev.initiation.prompt == ""
    assert ev.initiation.dynamic_variables == {}


def test_parse_pong_and_feedback():
    assert p.parse_client_event(b'{"type":"pong","event_id":4}').event_id == 4
    fb = p.parse_client_event(b'{"type":"feedback","score":"like","event_id":2}')
    assert (fb.score, fb.event_id) == ("like", 2)


def test_parse_tool_result():
    ev = p.parse_client_event(b'{"type":"client_tool_result","tool_call_id":"t1","result":"{\\"ok\\":true}","is_error":false}')
    assert (ev.tool_call_id, ev.result, ev.is_error) == ("t1", '{"ok":true}', False)
    err = p.parse_client_event(b'{"type":"client_tool_result","tool_call_id":"t2","result":"no","is_error":true,"error_type":"x"}')
    assert err.is_error is True
    # a non-string result is kept as its JSON
    obj = p.parse_client_event(b'{"type":"client_tool_result","tool_call_id":"t3","result":{"a":1},"is_error":false}')
    assert json.loads(obj.result) == {"a": 1}
    with pytest.raises(p.ProtocolError):
        p.parse_client_event(b'{"type":"client_tool_result","result":"x"}')


def test_parse_text_events():
    assert p.parse_client_event(b'{"type":"contextual_update","text":"focus s3"}').text == "focus s3"
    assert p.parse_client_event(b'{"type":"user_message","text":"[app] {}"}').text == "[app] {}"
    assert p.parse_client_event(b'{"type":"user_activity"}').type == "user_activity"


def test_parse_rejects_garbage():
    for raw in (b"not json", b"[1]", b'{"no":"type"}', b"\xff\xfe"):
        with pytest.raises(p.ProtocolError):
            p.parse_client_event(raw)


def test_substitute_variables():
    text, missing = p.substitute_variables(INIT["conversation_config_override"]["agent"]["prompt"]["prompt"], INIT["dynamic_variables"])
    assert text == "You are a voice. Context: the time is noon"
    assert missing == []
    text, missing = p.substitute_variables("a {{ x }} b {{y}}", {"x": 5})
    assert text == "a 5 b {{y}}"
    assert missing == ["y"]
