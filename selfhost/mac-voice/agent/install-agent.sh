#!/bin/bash
# Install the Happy voice agent worker as the launchd user agent com.happy.voice-agent.
#
#   ./agent/install-agent.sh              build the venv if missing, write the plist, (re)load it
#   ./agent/install-agent.sh --uninstall  unload it; the plist is moved to ~/trash, never deleted
#
# Needs ~/.config/happy-voice-agent/agent.env (chmod 600), see README.md ("Voice agent"). The worker
# registers as VOICE_AGENT_NAME (happy-voice) and is only dispatched explicitly by happy-server.
set -euo pipefail
VOICE_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$VOICE_DIR/../.." && pwd)
AGENT_DIR="$REPO/packages/happy-voice-agent"
LABEL=com.happy.voice-agent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
ENV_FILE="$HOME/.config/happy-voice-agent/agent.env"
UV="$HOME/.local/bin/uv"

trash() {
  local t="$HOME/trash/$(date +%Y%m%d_%H%M%S)_$LABEL"
  mkdir -p "$t" && mv "$1" "$t/"
  echo "moved $1 to $t"
}

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  [ -f "$PLIST" ] && trash "$PLIST"
  exit 0
fi

[ -r "$ENV_FILE" ] || { echo "create $ENV_FILE first (see README.md)" >&2; exit 1; }
chmod 600 "$ENV_FILE"

if [ ! -x "$AGENT_DIR/.venv/bin/python" ]; then
  "$UV" venv -p 3.12 "$AGENT_DIR/.venv"
  VIRTUAL_ENV="$AGENT_DIR/.venv" "$UV" pip install -r "$AGENT_DIR/requirements.txt"
  (cd "$AGENT_DIR" && .venv/bin/python agent.py download-files)
fi

mkdir -p "$VOICE_DIR/logs" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
[ -f "$PLIST" ] && trash "$PLIST"
sed -e "s#__HOME__#$HOME#g" -e "s#__REPO__#$REPO#g" -e "s#__VOICE_DIR__#$VOICE_DIR#g" \
  "$VOICE_DIR/agent/$LABEL.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
# bootstrap right after bootout can fail with EIO while launchd tears the old job down
for _ in 1 2 3 4 5; do launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break; sleep 2; done
launchctl print "$DOMAIN/$LABEL" | grep -E '^\s+(state|pid) =' || true
echo "log: $VOICE_DIR/logs/agent.log"
