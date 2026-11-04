#!/usr/bin/env bash
# Checks the running live-browser stack without printing any secret:
#   1. the controller's MCP endpoint refuses a request without the bearer token;
#   2. with the token it initializes and lists its tools;
#   3. noVNC offers only VNC password authentication, and refuses "None".
set -euo pipefail

API="${BROWSER_API:-http://127.0.0.1:8010}"
SECRETS="${HAPPY_BROWSER_HOME:-$HOME/.local/share/happy-browser}/secrets"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0

auth_header() { printf 'Authorization: Bearer %s\n' "$(cat "$SECRETS/api-token")"; }
ACCEPT='Accept: application/json, text/event-stream'
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"browser-verify","version":"1"}}}'

code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$API/mcp" \
  -H 'Content-Type: application/json' -H "$ACCEPT" -d "$INIT")
if [[ "$code" == 401 || "$code" == 403 ]]; then
  echo "ok   MCP without token: HTTP $code"
else
  echo "FAIL MCP without token: HTTP $code (expected 401/403)"; fail=1
fi

hdrs=$(mktemp); trap 'rm -f "$hdrs"' EXIT
curl -sS --max-time 15 -D "$hdrs" -o /dev/null -X POST "$API/mcp" \
  -H @<(auth_header) -H 'Content-Type: application/json' -H "$ACCEPT" -d "$INIT"
sid=$(awk 'tolower($1)=="mcp-session-id:"{print $2}' "$hdrs" | tr -d '\r')
sid_hdr=(); [[ -n "$sid" ]] && sid_hdr=(-H "Mcp-Session-Id: $sid")
curl -sS --max-time 10 -o /dev/null -X POST "$API/mcp" -H @<(auth_header) "${sid_hdr[@]}" \
  -H 'Content-Type: application/json' -H "$ACCEPT" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
tools=$(curl -sS --max-time 15 -X POST "$API/mcp" -H @<(auth_header) "${sid_hdr[@]}" \
  -H 'Content-Type: application/json' -H "$ACCEPT" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | sed -n 's/^data: //p; /^{/p' | python3 -I -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    msg = json.loads(line)
    names = [t["name"] for t in msg.get("result", {}).get("tools", [])]
    print(len(names), " ".join(sorted(names)))
    break
')
count=${tools%% *}
if [[ "${count:-0}" -gt 0 ]]; then
  echo "ok   MCP with token: $count tools"
  echo "     ${tools#* }" | fold -s -w 110 | sed '2,$s/^/     /'
else
  echo "FAIL MCP with token: no tools listed"; fail=1
fi

if node "$HERE/vnc-auth-check.mjs" "${NOVNC_URL:-ws://localhost:6080/websockify}"; then :; else fail=1; fi
exit $fail
