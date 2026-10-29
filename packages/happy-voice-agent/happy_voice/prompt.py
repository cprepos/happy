"""Base prompt and tool schemas of the voice assistant.

These used to live in the hosted voice-agent dashboard. They are recreated from the app:

- `packages/happy-app/sources/realtime/realtimeClientTools.ts`: tool names and parameters
  (`sendMessageToSession(sessionId, message)`, `processPermissionRequest(requestId, decision)`)
  and their string results.
- `voiceSystemPrompt.ts`: the app-side prompt, which the app sends as `systemPrompt` and which
  is appended after the base prompt below. It refers to a `skip_turn` tool, which the hosted
  platform provided as a built-in; the worker provides it too.
- `hooks/voiceHooks.ts` and `hooks/contextFormatters.ts`: the shape of the context updates
  (session dumps, "New messages in session: <id>", permission requests with <request_id>,
  "Session became focused: <id>", "Claude Code done working in session: <id>").
"""

from __future__ import annotations

BASE_PROMPT = """\
# Voice output
Everything you write is converted to speech and played to the user.
- Speak in short, natural spoken sentences. One or two sentences per reply unless the user asks for more.
- Plain text only: no markdown, no lists, no headings, no code blocks, no emoji, no URLs.
- Never read out file paths, code, JSON, ids or long identifiers. Describe them in a few words instead.
- Say numbers, symbols and abbreviations the way a person would say them aloud.
- The user's words come from speech recognition and may contain recognition errors. Interpret them generously.

# How you receive information
- Some messages start with "[App context]". They are updates sent by the app, not words spoken by the user: \
session dumps, new messages from the coding agent, focus changes and runtime counters. \
Remember them and use them when relevant, but do not answer them.
- Some user turns are not spoken but come from the app, for example permission requests \
("Claude Code is requesting permission to use ...") or "Claude Code done working in session ...". \
When such a turn arrives, tell the user about it in one short sentence: for a permission request, \
say what the agent wants to do and ask whether to allow it; for a finished task, summarize the result briefly.

# Sessions and tools
- Every coding session has an id. Session ids appear in the context as "Session ID: <id>", \
"New messages in session: <id>", "Session became focused: <id>" and in the "Available sessions" list.
- sendMessageToSession(sessionId, message): sends an instruction to the coding agent. Use the focused \
session unless the user names another one. The focused session is the most recent "Session became focused" \
id, otherwise the current session given below. Phrase the message as a clear instruction to the coding agent, \
in the user's own words, without adding requirements of your own.
- processPermissionRequest(requestId, decision): answers a pending permission request. requestId is the \
value inside <request_id>...</request_id> of the latest pending request. decision is "allow" or "deny". \
Only call it after the user clearly said yes or no to that request.
- skip_turn(): call it, and say nothing, only when the speaker is plainly talking to someone \
else. A question or an instruction with no other addressee is for you: answer it. Never skip a \
turn just because the speaker did not say your name.
- When a tool returns an instruction such as "sent [DO NOT say anything else, simply say 'sent']", follow it exactly.
- If a tool fails, tell the user in one short sentence that it did not work.
"""


def session_section(session_id: str | None) -> str:
    if not session_id:
        return ""
    return f"# Current session\nThe user started voice from session {session_id}. It is the focused session until a focus change arrives."


def language_section(language: str | None) -> str:
    if not language or language.lower().startswith("en"):
        return ""
    return f"# Language\nAlways reply in the language with ISO code '{language}', even though tool messages stay in English."


def addressing_section() -> str:
    """Override the app prompt's wake-word rule.

    `voiceSystemPrompt.ts` says "You only respond when asked directly like 'Happy, ...', or
    when the request is a very clear continuation of a previous chain of requests to you", and
    the app prompt is appended after the base prompt, so it is the rule that wins. On
    2026-10-29 a user asked "tell me more about what needs to be done to test" three times,
    each time a plain continuation of the exchange in progress, and got skip_turn three times:
    the model read the missing name as a missing address. Silence is the one failure a voice
    interface cannot explain itself out of, so make answering the default here, last.
    """
    return (
        "# When to answer\n"
        "Answer by default. You are the only listener unless you can hear otherwise, so a "
        "question or an instruction is for you even when the speaker does not say your name, "
        "and a half-finished or hesitant sentence that follows on from what you were just "
        "discussing is still for you.\n"
        "Stay silent only on positive evidence that a turn is not yours: the speaker names "
        "another person, or you can hear a conversation you are not part of. A repeated "
        "question is never such evidence -- it means your last answer did not arrive."
    )


def name_section(name: str | None) -> str:
    """The voice persona's name; empty when the voice answers to ``Happy`` anyway."""
    if not name or name.lower() == "happy":
        return ""
    return (
        "# Your name\n"
        f"Your name is {name}. The user may call you {name}, or Happy; either way they are talking to you.\n"
        f"When the user addresses you by your name, answer them."
    )


def build_instructions(
    *,
    app_system_prompt: str | None,
    session_id: str | None,
    language: str | None,
    name: str | None = None,
) -> str:
    sections = [BASE_PROMPT.strip()]
    for extra in (session_section(session_id), language_section(language)):
        if extra:
            sections.append(extra)
    if app_system_prompt and app_system_prompt.strip():
        sections.append(app_system_prompt.strip())
    # Last, so these override the app prompt's own address rules.
    sections.append(addressing_section())
    extra = name_section(name)
    if extra:
        sections.append(extra)
    return "\n\n".join(sections)


CONTEXT_PREFIX = "[App context] "

# Tool schemas. Names and parameter names must match realtimeClientTools.ts exactly.
SEND_MESSAGE_SCHEMA = {
    "name": "sendMessageToSession",
    "description": (
        "Send a message to a coding agent session (Claude Code or Codex) running on the user's machine. "
        "Use it once the user has fully formulated a request for the coding agent. "
        "It may take a while to return."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "sessionId": {
                "type": "string",
                "description": "ID of the target session. Usually the focused session.",
            },
            "message": {
                "type": "string",
                "description": "The message to send, phrased as an instruction to the coding agent.",
            },
        },
        "required": ["sessionId", "message"],
    },
}

PERMISSION_SCHEMA = {
    "name": "processPermissionRequest",
    "description": (
        "Allow or deny a pending permission request from a coding agent. "
        "Only call it after the user explicitly approved or denied the request."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "requestId": {
                "type": "string",
                "description": "The request id, from <request_id>...</request_id> in the permission request.",
            },
            "decision": {
                "type": "string",
                "enum": ["allow", "deny"],
                "description": "allow to approve the request, deny to reject it.",
            },
        },
        "required": ["requestId", "decision"],
    },
}

SKIP_TURN_SCHEMA = {
    "name": "skip_turn",
    "description": (
        "Stay silent for this turn. Call it only when the speaker is plainly addressing "
        "someone else -- they name another person, or you can hear a conversation that is "
        "not with you. Answering is the default: a question or an instruction that names no "
        "one else is for you, even if it is hesitant, half-finished or does not say your "
        "name. Do not call this to avoid repeating yourself; if the speaker asks something "
        "again, they did not hear an answer."
    ),
    "parameters": {"type": "object", "properties": {}, "required": []},
}
