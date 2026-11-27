"""The ElevenLabs conversational-agent data-channel protocol, as the Swift SDK 3.4.0 speaks it.

The SDK (ElevenLabsSwift 3.4.0) joins a LiveKit room, waits for a participant whose identity
starts with "agent", then exchanges JSON events with it over reliable data packets (no topic).

Agent -> client events are built here with exactly the fields the SDK's EventParser reads
(Internal/Utilities/EventParser.swift). A known type with a missing or mistyped field makes the
SDK drop it as invalidEventData, so `validate_agent_event` checks those rules the way Swift's
`as? Int` / `as? String` / `as? Double` / `as? Bool` casts do, only stricter: an Int must be a
JSON integer (never a bool), a Bool a JSON bool, and a type the SDK does not know is an error.

Client -> agent events (Internal/Utilities/EventSerializer.swift) are parsed by `parse_client_event`.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

# The SDK's default agent output and user input formats; it reads them as strings and only
# stores them (ConversationMetadataEvent). Audio itself travels as LiveKit tracks.
AUDIO_FORMAT = "pcm_48000"

# Tool types the hosted agent reports in agent_tool_request / agent_tool_response.
TOOL_TYPE_SYSTEM = "system"
TOOL_TYPE_CLIENT = "client"

END_CALL_TOOL = "end_call"

# Agent -> client events the SDK 3.4.0 parser knows, with the fields it requires.
# Each entry: type -> (envelope key, {field: kind}); kind is one of int, str, float, bool, dict,
# optional_int, any. "client_error" parses without any field and is handled separately.
_AGENT_EVENT_RULES: dict[str, tuple[str, dict[str, str]]] = {
    "user_transcript": ("user_transcription_event", {"user_transcript": "str", "event_id": "int"}),
    "agent_response": (
        "agent_response_event",
        {"agent_response": "str", "event_id": "int", "response_id": "str"},
    ),
    "agent_response_correction": (
        "agent_response_correction_event",
        {
            "original_agent_response": "str",
            "corrected_agent_response": "str",
            "event_id": "int",
            "response_id": "str",
        },
    ),
    "agent_response_metadata": ("agent_response_metadata_event", {"event_id": "int", "metadata": "dict"}),
    "audio": ("audio_event", {"event_id": "int"}),
    "interruption": ("interruption_event", {"event_id": "int"}),
    "vad_score": ("vad_score_event", {"vad_score": "float"}),
    "internal_tentative_agent_response": (
        "tentative_agent_response_internal_event",
        {"tentative_agent_response": "str"},
    ),
    "conversation_initiation_metadata": (
        "conversation_initiation_metadata_event",
        {"conversation_id": "str", "agent_output_audio_format": "str", "user_input_audio_format": "str"},
    ),
    "ping": ("ping_event", {"event_id": "int", "ping_ms": "optional_int"}),
    "client_tool_call": (
        "client_tool_call",
        {
            "tool_name": "str",
            "tool_call_id": "str",
            "parameters": "dict",
            "event_id": "int",
            "expects_response": "bool",
        },
    ),
    "agent_tool_request": (
        "agent_tool_request",
        {"tool_name": "str", "tool_call_id": "str", "tool_type": "str", "event_id": "int"},
    ),
    "agent_tool_response": (
        "agent_tool_response",
        {"tool_name": "str", "tool_call_id": "str", "tool_type": "str", "is_error": "bool", "event_id": "int"},
    ),
    "tentative_user_transcript": (
        "tentative_user_transcription_event",
        {"user_transcript": "str", "event_id": "int"},
    ),
    "agent_chat_response_part": (
        "text_response_part",
        {"text": "str", "event_id": "int", "response_id": "str"},
    ),
}

# Parsed by the SDK too, but with nested shapes this worker never sends.
_AGENT_EVENTS_UNCHECKED = {"mcp_tool_call", "mcp_connection_status", "asr_initiation_metadata"}

KNOWN_AGENT_EVENTS = frozenset(_AGENT_EVENT_RULES) | _AGENT_EVENTS_UNCHECKED | {"client_error"}


def _is_kind(value: Any, kind: str) -> bool:
    if kind == "int":
        return isinstance(value, int) and not isinstance(value, bool)
    if kind == "optional_int":
        return value is None or (isinstance(value, int) and not isinstance(value, bool))
    if kind == "str":
        return isinstance(value, str)
    if kind == "float":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if kind == "bool":
        return isinstance(value, bool)
    if kind == "dict":
        return isinstance(value, dict)
    return True


def validate_agent_event(event: Any) -> list[str]:
    """Every way `event` (decoded JSON) breaks the SDK 3.4.0 parser's rules; empty when it parses."""
    if not isinstance(event, dict):
        return ["not a JSON object"]
    kind = event.get("type")
    if not isinstance(kind, str):
        return ["no string 'type'"]
    if kind == "client_error":
        body = event.get("error_event")
        if body is None:
            return []
        if not isinstance(body, dict):
            return ["client_error: error_event is not an object"]
        errors = []
        for name, want in (("code", "optional_int"), ("message", "str"), ("error_name", "str")):
            if name in body and body[name] is not None and not _is_kind(body[name], want):
                errors.append(f"client_error: {name} has the wrong type")
        return errors
    if kind in _AGENT_EVENTS_UNCHECKED:
        return []
    rule = _AGENT_EVENT_RULES.get(kind)
    if rule is None:
        return [f"unknown event type {kind!r}"]
    envelope, fields = rule
    body = event.get(envelope)
    if not isinstance(body, dict):
        return [f"{kind}: missing object {envelope!r}"]
    errors = []
    for name, want in fields.items():
        if want == "optional_int" and name not in body:
            continue
        if name not in body:
            errors.append(f"{kind}: missing {envelope}.{name}")
        elif not _is_kind(body[name], want):
            errors.append(f"{kind}: {envelope}.{name} is not {want} ({type(body[name]).__name__})")
    return errors


def encode(event: dict[str, Any]) -> bytes:
    """The wire bytes of an agent event; raises ValueError if the SDK would not parse it."""
    if errors := validate_agent_event(event):
        raise ValueError("; ".join(errors))
    return json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


# --- agent -> client builders ---------------------------------------------------------------


def conversation_initiation_metadata(
    conversation_id: str, agent_format: str = AUDIO_FORMAT, user_format: str = AUDIO_FORMAT
) -> dict[str, Any]:
    return {
        "type": "conversation_initiation_metadata",
        "conversation_initiation_metadata_event": {
            "conversation_id": conversation_id,
            "agent_output_audio_format": agent_format,
            "user_input_audio_format": user_format,
        },
    }


def user_transcript(text: str, event_id: int) -> dict[str, Any]:
    return {
        "type": "user_transcript",
        "user_transcription_event": {"user_transcript": text, "event_id": int(event_id)},
    }


def tentative_user_transcript(text: str, event_id: int) -> dict[str, Any]:
    return {
        "type": "tentative_user_transcript",
        "tentative_user_transcription_event": {"user_transcript": text, "event_id": int(event_id)},
    }


def agent_response(text: str, event_id: int, response_id: str) -> dict[str, Any]:
    return {
        "type": "agent_response",
        "agent_response_event": {
            "agent_response": text,
            "event_id": int(event_id),
            "response_id": response_id,
        },
    }


def agent_response_correction(original: str, corrected: str, event_id: int, response_id: str) -> dict[str, Any]:
    return {
        "type": "agent_response_correction",
        "agent_response_correction_event": {
            "original_agent_response": original,
            "corrected_agent_response": corrected,
            "event_id": int(event_id),
            "response_id": response_id,
        },
    }


def interruption(event_id: int) -> dict[str, Any]:
    return {"type": "interruption", "interruption_event": {"event_id": int(event_id)}}


def vad_score(score: float) -> dict[str, Any]:
    return {"type": "vad_score", "vad_score_event": {"vad_score": float(score)}}


def ping(event_id: int, ping_ms: int | None = None) -> dict[str, Any]:
    body: dict[str, Any] = {"event_id": int(event_id)}
    if ping_ms is not None:
        body["ping_ms"] = int(ping_ms)
    return {"type": "ping", "ping_event": body}


def client_tool_call(
    tool_name: str, tool_call_id: str, parameters: dict[str, Any], event_id: int, expects_response: bool = True
) -> dict[str, Any]:
    return {
        "type": "client_tool_call",
        "client_tool_call": {
            "tool_name": tool_name,
            "tool_call_id": tool_call_id,
            "parameters": dict(parameters),
            "event_id": int(event_id),
            "expects_response": bool(expects_response),
        },
    }


def agent_tool_request(tool_name: str, tool_call_id: str, event_id: int, tool_type: str = TOOL_TYPE_SYSTEM) -> dict[str, Any]:
    return {
        "type": "agent_tool_request",
        "agent_tool_request": {
            "tool_name": tool_name,
            "tool_call_id": tool_call_id,
            "tool_type": tool_type,
            "event_id": int(event_id),
        },
    }


def agent_tool_response(
    tool_name: str, tool_call_id: str, event_id: int, *, is_error: bool = False, tool_type: str = TOOL_TYPE_SYSTEM
) -> dict[str, Any]:
    return {
        "type": "agent_tool_response",
        "agent_tool_response": {
            "tool_name": tool_name,
            "tool_call_id": tool_call_id,
            "tool_type": tool_type,
            "is_error": bool(is_error),
            "event_id": int(event_id),
        },
    }


def client_error(message: str, code: int = 1011, error_name: str | None = None) -> dict[str, Any]:
    body: dict[str, Any] = {"code": int(code), "message": message}
    if error_name:
        body["error_name"] = error_name
    return {"type": "client_error", "error_event": body}


# --- client -> agent ------------------------------------------------------------------------


@dataclass
class InitiationData:
    """conversation_initiation_client_data, as SDK 3.4.0 serializes ConversationConfig."""

    prompt: str = ""
    first_message: str = ""
    language: str = ""
    voice_id: str = ""
    speed: float | None = None
    text_only: bool = False
    dynamic_variables: dict[str, Any] = field(default_factory=dict)
    custom_llm_extra_body: dict[str, Any] = field(default_factory=dict)
    user_id: str = ""
    source: str = ""
    version: str = ""


@dataclass
class ClientEvent:
    type: str
    # pong / feedback: the event id they answer
    event_id: int | None = None
    # client_tool_result
    tool_call_id: str = ""
    result: str = ""
    is_error: bool = False
    # contextual_update / user_message
    text: str = ""
    # feedback
    score: str = ""
    initiation: InitiationData | None = None
    raw: dict[str, Any] = field(default_factory=dict)


class ProtocolError(ValueError):
    pass


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _str(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def _parse_initiation(data: dict[str, Any]) -> InitiationData:
    override = _dict(data.get("conversation_config_override"))
    agent = _dict(override.get("agent"))
    tts = _dict(override.get("tts"))
    conversation = _dict(override.get("conversation"))
    source = _dict(data.get("source_info"))
    speed = tts.get("speed")
    return InitiationData(
        prompt=_str(_dict(agent.get("prompt")).get("prompt")),
        first_message=_str(agent.get("first_message")),
        language=_str(agent.get("language")),
        voice_id=_str(tts.get("voice_id")),
        speed=float(speed) if isinstance(speed, (int, float)) and not isinstance(speed, bool) else None,
        text_only=conversation.get("text_only") is True,
        dynamic_variables=_dict(data.get("dynamic_variables")),
        custom_llm_extra_body=_dict(data.get("custom_llm_extra_body")),
        user_id=_str(data.get("user_id")),
        source=_str(source.get("source")),
        version=_str(source.get("version")),
    )


def parse_client_event(payload: bytes | str) -> ClientEvent:
    """One event the SDK sent; raises ProtocolError for anything that is not a typed JSON object."""
    try:
        data = json.loads(payload)
    except (ValueError, UnicodeDecodeError) as e:
        raise ProtocolError(f"not JSON: {e}") from e
    if not isinstance(data, dict) or not isinstance(data.get("type"), str):
        raise ProtocolError("not a typed JSON object")
    kind = data["type"]
    event = ClientEvent(type=kind, raw=data)
    if kind == "conversation_initiation_client_data":
        event.initiation = _parse_initiation(data)
    elif kind in ("pong", "feedback"):
        event.event_id = _int(data.get("event_id"))
        event.score = _str(data.get("score"))
    elif kind == "client_tool_result":
        event.tool_call_id = _str(data.get("tool_call_id"))
        result = data.get("result")
        event.result = result if isinstance(result, str) else json.dumps(result)
        event.is_error = data.get("is_error") is True
        if not event.tool_call_id:
            raise ProtocolError("client_tool_result without tool_call_id")
    elif kind in ("contextual_update", "user_message"):
        event.text = _str(data.get("text"))
    return event


# --- dynamic variables ----------------------------------------------------------------------

_VARIABLE_RE = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_\-]*)\s*\}\}")


def substitute_variables(text: str, variables: dict[str, Any]) -> tuple[str, list[str]]:
    """`text` with each {{name}} replaced by variables[name], as the hosted agent does with the
    app's dynamic variables; also the names that had no value (left as they were)."""
    missing: list[str] = []

    def repl(m: re.Match[str]) -> str:
        name = m.group(1)
        if name not in variables or variables[name] is None:
            missing.append(name)
            return m.group(0)
        value = variables[name]
        return value if isinstance(value, str) else json.dumps(value)

    return _VARIABLE_RE.sub(repl, text), missing
