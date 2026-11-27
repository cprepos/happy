#!/bin/sh
# launchd wrapper for the voice agent worker that speaks the ElevenLabs SDK protocol
# (packages/happy-voice-agent/agent_el.py). Reads its settings, secrets included, from
# ~/.config/happy-voice-agent/agent-el.env (chmod 600), kept out of git. Installed as
# com.happy.voice-agent-el by install-agent-el.sh, beside com.happy.voice-agent.
set -eu
REPO=${HAPPY_REPO:-$HOME/happy}
AGENT_DIR="$REPO/packages/happy-voice-agent"
ENV_FILE=${VOICE_AGENT_EL_ENV:-$HOME/.config/happy-voice-agent/agent-el.env}
[ -r "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
set -a
. "$ENV_FILE"
set +a
cd "$AGENT_DIR"
exec "$AGENT_DIR/.venv/bin/python" agent_el.py start
