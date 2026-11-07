"""Which Happy Agent chat made a tool call: read-only lookup in the daemon's own database.

Usage: python3 -I agentchat.py <agent.sqlite> <tool call id> [wait_ms]
       python3 -I agentchat.py <agent.sqlite> --match [wait_ms]   (request JSON on stdin)

Happy Agent journals every tool call it starts (event type tool.started, with the agent that made
it) before it runs the tool, and keeps the Happy session each agent is mirrored to. Prints one JSON
line: {"agent": <agent id>, "happy": <Happy session id or null>}, or {"agent": null} when the call
is not found within wait_ms. Opens the database read-only and reads only those ids, never the
session keys stored beside them.

--match is for a daemon that names no call id on the wire (its MCP requests carry no _meta): stdin
is {"name": <MCP tool name>, "arguments": {...}, "claimed": [<call ids already matched>]}, and the
call is the one tool.started event for that tool, with exactly those arguments, that has not
completed and was not matched before. The answer adds "call": <its call id>. When such calls are
in flight for more than one agent the answer is {"agent": null, "ambiguous": true}: which chat
this one is can't be told, so none is named.

The daemon may run on another machine (a Mac whose Happy Agent reaches this bridge over ssh): then
the bridge runs this script there as `ssh <host> python3 -I - <agent.sqlite> ...`, with the script
on stdin, preceded in --match mode by a line REQUEST_JSON = "<the request>".
"""
import json
import sqlite3
import sys
import time

# The newest journal rows are enough: the call being looked up is in flight.
CALL = """
SELECT agent_id FROM (
    SELECT agent_id, type, payload_json FROM happy_agent_events ORDER BY event_id DESC LIMIT 5000
) WHERE type = 'tool.started' AND agent_id IS NOT NULL
  AND json_extract(payload_json, '$.rigEvent.toolCall.id') = ?
LIMIT 1
"""
CALL_HISTORY = "SELECT agent_id FROM happy_agent_module_history_tool_calls WHERE call_id = ? LIMIT 1"
HAPPY = """
SELECT remote_session_id FROM happy_agent_happy_sessions
WHERE agent_id = ? AND remote_session_id IS NOT NULL AND remote_session_id != ''
ORDER BY updated_at_ms DESC LIMIT 1
"""
# Calls started in the last few minutes, newest first, and the calls among them that completed.
RECENT = """
SELECT event_id, agent_id, type, occurred_at,
       json_extract(payload_json, '$.rigEvent.toolCall.id'),
       json_extract(payload_json, '$.rigEvent.toolCall.name'),
       json_extract(payload_json, '$.rigEvent.toolCall.arguments'),
       json_extract(payload_json, '$.callId')
FROM (SELECT * FROM happy_agent_events ORDER BY event_id DESC LIMIT 2000)
WHERE type IN ('tool.started', 'tool.completed') AND occurred_at >= ?
ORDER BY event_id
"""
RECENT_MS = 10 * 60 * 1000  # the longest a tool call may run (Happy Agent allows at most 600 s)


def happy_of(conn, agent):
    try:
        row = conn.execute(HAPPY, (agent,)).fetchone()
    except sqlite3.OperationalError:  # no Happy integration on this daemon
        row = None
    return row[0] if row else None


def by_id(conn, call_id, wait_s):
    deadline = time.monotonic() + wait_s
    agent = None
    while True:
        for q in (CALL, CALL_HISTORY):
            try:
                row = conn.execute(q, (call_id,)).fetchone()
            except sqlite3.OperationalError:
                row = None
            if row:
                agent = row[0]
                break
        if agent or time.monotonic() >= deadline:
            break
        time.sleep(0.04)
    return {"agent": agent, "happy": happy_of(conn, agent) if agent else None}


def tool_matches(journal_name, name):
    # The daemon names an MCP tool mcp__<server>__<tool>; the server sees <tool>.
    return journal_name == name or (journal_name.startswith("mcp__") and journal_name.endswith("__" + name))


def candidates(conn, name, arguments, claimed):
    rows = conn.execute(RECENT, (int(time.time() * 1000) - RECENT_MS,)).fetchall()
    done = {r[7] for r in rows if r[2] == "tool.completed" and r[7]}
    out = []  # (call id, agent), oldest first
    for _eid, agent, typ, _at, call_id, tool, args_json, _ in rows:
        if typ != "tool.started" or not agent or not call_id or not isinstance(tool, str):
            continue
        if call_id in done or call_id in claimed or not tool_matches(tool, name):
            continue
        try:
            args = json.loads(args_json) if args_json is not None else {}
        except ValueError:
            continue
        if (args or {}) == arguments:
            out.append((call_id, agent))
    return out


def by_match(conn, req, wait_s):
    name = req.get("name")
    arguments = req.get("arguments") or {}
    claimed = set(req.get("claimed") or [])
    if not isinstance(name, str) or not name or not isinstance(arguments, dict):
        return {"agent": None}
    deadline = time.monotonic() + wait_s
    while True:
        try:
            found = candidates(conn, name, arguments, claimed)
        except sqlite3.OperationalError:
            found = []
        agents = {a for _, a in found}
        if len(agents) > 1:
            return {"agent": None, "ambiguous": True}
        if agents:
            call_id, agent = found[0]
            return {"agent": agent, "happy": happy_of(conn, agent), "call": call_id}
        if time.monotonic() >= deadline:
            return {"agent": None}
        time.sleep(0.04)


def main():
    db = sys.argv[1]
    match = len(sys.argv) > 2 and sys.argv[2] == "--match"
    wait_arg = sys.argv[3] if len(sys.argv) > 3 else None
    wait_s = (int(wait_arg) if wait_arg else 1500) / 1000
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1)
    if match:
        # Run over ssh as `python3 -I -`, the script itself is stdin and the request comes first in it.
        req = globals().get("REQUEST_JSON")
        print(json.dumps(by_match(conn, json.loads(req if req is not None else (sys.stdin.read() or "{}")), wait_s)))
    else:
        print(json.dumps(by_id(conn, sys.argv[2], wait_s)))


if __name__ == "__main__":
    main()
