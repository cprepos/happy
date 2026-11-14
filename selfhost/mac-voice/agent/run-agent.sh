#!/bin/sh
# launchd wrapper for the Happy voice agent worker (packages/happy-voice-agent) on a Mac.
# Reads its settings, secrets included, from ~/.config/happy-voice-agent/agent.env (chmod 600),
# which is kept out of git. Installed as com.happy.voice-agent by install-agent.sh.
set -eu
REPO=${HAPPY_REPO:-$HOME/happy}
AGENT_DIR="$REPO/packages/happy-voice-agent"
ENV_FILE=${VOICE_AGENT_ENV:-$HOME/.config/happy-voice-agent/agent.env}
[ -r "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
set -a
. "$ENV_FILE"
set +a
cd "$AGENT_DIR"
exec "$AGENT_DIR/.venv/bin/python" agent.py start
