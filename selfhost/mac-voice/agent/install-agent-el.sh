#!/bin/bash
# Install the ElevenLabs-protocol voice agent worker as the launchd user agent
# com.happy.voice-agent-el, beside com.happy.voice-agent (which this never touches).
#
#   ./agent/install-agent-el.sh              write agent-el.env if missing, write the plist, (re)load it
#   ./agent/install-agent-el.sh --uninstall  unload it; the plist is moved to ~/trash, never deleted
#
# Uses the venv install-agent.sh builds. Its env file, ~/.config/happy-voice-agent/agent-el.env
# (chmod 600), is created once from agent.env with VOICE_AGENT_NAME=happy-voice-el and its own
# health port VOICE_AGENT_HTTP_PORT=8792; after that it is never rewritten.
set -euo pipefail
VOICE_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$VOICE_DIR/../.." && pwd)
AGENT_DIR="$REPO/packages/happy-voice-agent"
LABEL=com.happy.voice-agent-el
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
BASE_ENV="$HOME/.config/happy-voice-agent/agent.env"
ENV_FILE="$HOME/.config/happy-voice-agent/agent-el.env"
EL_NAME=${EL_AGENT_NAME:-happy-voice-el}
EL_PORT=${EL_AGENT_HTTP_PORT:-8792}

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

[ -x "$AGENT_DIR/.venv/bin/python" ] || { echo "no venv at $AGENT_DIR/.venv: run install-agent.sh first" >&2; exit 1; }

if [ ! -e "$ENV_FILE" ]; then
  [ -r "$BASE_ENV" ] || { echo "create $BASE_ENV first (see README.md)" >&2; exit 1; }
  umask 077
  grep -vE '^(VOICE_AGENT_NAME|VOICE_AGENT_HTTP_PORT)=' "$BASE_ENV" > "$ENV_FILE"
  printf 'VOICE_AGENT_NAME=%s\nVOICE_AGENT_HTTP_PORT=%s\n' "$EL_NAME" "$EL_PORT" >> "$ENV_FILE"
  echo "wrote $ENV_FILE from $BASE_ENV (agent $EL_NAME, health port $EL_PORT)"
fi
chmod 600 "$ENV_FILE"

mkdir -p "$VOICE_DIR/logs" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
[ -f "$PLIST" ] && trash "$PLIST"
sed -e "s#__HOME__#$HOME#g" -e "s#__REPO__#$REPO#g" -e "s#__VOICE_DIR__#$VOICE_DIR#g" \
  "$VOICE_DIR/agent/$LABEL.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
# bootstrap right after bootout can fail with EIO while launchd tears the old job down
for _ in 1 2 3 4 5; do launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break; sleep 2; done
launchctl print "$DOMAIN/$LABEL" | grep -E '^\s+(state|pid) =' || true
echo "log: $VOICE_DIR/logs/agent-el.log"
