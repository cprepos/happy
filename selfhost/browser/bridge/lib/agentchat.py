"""Which Happy Agent chat made a tool call: read-only lookup in the daemon's own database.

Usage: python3 -I agentchat.py <agent.sqlite> <tool call id> [wait_ms]

Happy Agent journals every tool call it starts (event type tool.started, with the agent that made
it) before it runs the tool, and keeps the Happy session each agent is mirrored to. Prints one JSON
line: {"agent": <agent id>, "happy": <Happy session id or null>}, or {"agent": null} when the call
is not found within wait_ms. Opens the database read-only and reads only those ids, never the
session keys stored beside them.
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


def main():
    db, call_id = sys.argv[1], sys.argv[2]
    wait_s = (int(sys.argv[3]) if len(sys.argv) > 3 else 1500) / 1000
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1)
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
    happy = None
    if agent:
        try:
            row = conn.execute(HAPPY, (agent,)).fetchone()
        except sqlite3.OperationalError:  # no Happy integration on this daemon
            row = None
        happy = row[0] if row else None
    print(json.dumps({"agent": agent, "happy": happy}))


if __name__ == "__main__":
    main()
