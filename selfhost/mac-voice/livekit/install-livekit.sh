#!/bin/bash
# Install the LiveKit server as the launchd user agent com.happy.livekit.
#
#   ./livekit/install-livekit.sh              write the plist, (re)load it
#   ./livekit/install-livekit.sh --uninstall  unload it; the plist is moved to ~/trash, never deleted
#
# Runs Homebrew's livekit-server (brew install livekit) with ../livekit.yaml from this checkout.
# The yaml has no secrets; its key_file is ~/.config/livekit/keys.yaml (chmod 600), see README.md
# ("LiveKit and the voice agent"). The voice agent (com.happy.voice-agent) connects to it on
# ws://127.0.0.1:7880.
set -euo pipefail
VOICE_DIR=$(cd "$(dirname "$0")/.." && pwd)
LABEL=com.happy.livekit
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
KEY_FILE="$HOME/.config/livekit/keys.yaml"
LIVEKIT_BIN=${LIVEKIT_BIN:-/opt/homebrew/bin/livekit-server}

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

[ -x "$LIVEKIT_BIN" ] || { echo "$LIVEKIT_BIN missing: brew install livekit" >&2; exit 1; }
[ -r "$KEY_FILE" ] || { echo "create $KEY_FILE first (see README.md)" >&2; exit 1; }
chmod 600 "$KEY_FILE"
[ -r "$VOICE_DIR/livekit.yaml" ] || { echo "$VOICE_DIR/livekit.yaml missing" >&2; exit 1; }

mkdir -p "$VOICE_DIR/logs" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
[ -f "$PLIST" ] && trash "$PLIST"
sed -e "s#__HOME__#$HOME#g" -e "s#__VOICE_DIR__#$VOICE_DIR#g" -e "s#__LIVEKIT_BIN__#$LIVEKIT_BIN#g" \
  "$VOICE_DIR/livekit/$LABEL.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
# bootstrap right after bootout can fail with EIO while launchd tears the old job down
for _ in 1 2 3 4 5; do launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break; sleep 2; done
launchctl print "$DOMAIN/$LABEL" | grep -E '^\s+(state|pid) =' || true
echo "log: $VOICE_DIR/logs/livekit.log"
