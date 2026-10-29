#!/bin/bash
# Install the local STT + TTS as launchd services: they start at login and are restarted
# whenever they stop. Plain HTTP on the LAN, no tunnel.
#
#   ./install-service.sh                       install; only ALLOW_FROM may connect (default 192.168.2.72)
#   ALLOW_FROM=any ./install-service.sh        install; anyone on the LAN may connect
#   ./install-service.sh --uninstall           remove the services and the firewall rules
#
# Settings (env): VOICE_DIR (~/happy-voice-local), VOICE_HOST (0.0.0.0), STT_PORT (8090),
# TTS_PORT (8880), ALLOW_FROM (192.168.2.72, or "any"), TTS_MODEL (prince-canuma/Kokoro-82M),
# TTS_VOICE (af_heart), TTS_FIRST_MAX_WORDS (8).
#
# TTS_MODEL and TTS_VOICE are written into the plist, so a fine-tuned Kokoro survives a
# reinstall. Point TTS_MODEL at a directory holding the model and a voices/*.safetensors
# folder; anything that is not a directory is resolved against Hugging Face. For example:
#
#   TTS_MODEL=$HOME/kokoro-am-morgan TTS_VOICE=am_morgan ./install-service.sh
#
# The services have no authentication. The allow rule (a pf anchor, reloaded at boot by a small
# LaunchDaemon) keeps other LAN devices out. Firewall steps use sudo and ask for your password.
#
# launchd user agents start when you log in. To have them up after a reboot without anyone
# logging in, turn on automatic login (System Settings > Users & Groups).
set -euo pipefail

VOICE_DIR=${VOICE_DIR:-$HOME/happy-voice-local}
VOICE_HOST=${VOICE_HOST:-0.0.0.0}
STT_PORT=${STT_PORT:-8090}
TTS_PORT=${TTS_PORT:-8880}
ALLOW_FROM=${ALLOW_FROM:-192.168.2.72}
# Defaults are the stock hub model and voice, so a fresh install works with no local files.
TTS_MODEL=${TTS_MODEL:-prince-canuma/Kokoro-82M}
TTS_VOICE=${TTS_VOICE:-af_heart}
TTS_FIRST_MAX_WORDS=${TTS_FIRST_MAX_WORDS:-8}

AGENTS="$HOME/Library/LaunchAgents"
LABEL_PREFIX=com.happy.voice
PF_ANCHOR_NAME=com.apple/250.HappyVoice
PF_ANCHOR_FILE=/etc/pf.anchors/com.happy.voice
PF_DAEMON=/Library/LaunchDaemons/com.happy.voice-pf.plist
DOMAIN="gui/$(id -u)"
PY="$VOICE_DIR/.venv/bin/python"

say() { printf '\n== %s\n' "$*"; }

unload_agent() {
  launchctl bootout "$DOMAIN/$LABEL_PREFIX-$1" 2>/dev/null || true
}

remove_pf() {
  sudo pfctl -a "$PF_ANCHOR_NAME" -F all 2>/dev/null || true
  if [ -f "$PF_DAEMON" ]; then
    sudo launchctl bootout system "$PF_DAEMON" 2>/dev/null || true
    sudo mkdir -p /var/tmp/happy-voice-trash && sudo mv "$PF_DAEMON" "/var/tmp/happy-voice-trash/$(date +%Y%m%d_%H%M%S)_$(basename "$PF_DAEMON")"
  fi
  if [ -f "$PF_ANCHOR_FILE" ]; then
    sudo mkdir -p /var/tmp/happy-voice-trash && sudo mv "$PF_ANCHOR_FILE" "/var/tmp/happy-voice-trash/$(date +%Y%m%d_%H%M%S)_$(basename "$PF_ANCHOR_FILE")"
  fi
}

if [ "${1:-}" = "--uninstall" ]; then
  say "removing launchd services"
  trash="$VOICE_DIR/trash/$(date +%Y%m%d_%H%M%S)_launchd_uninstall"
  mkdir -p "$trash"
  for svc in stt tts; do
    unload_agent "$svc"
    [ -f "$AGENTS/$LABEL_PREFIX-$svc.plist" ] && mv "$AGENTS/$LABEL_PREFIX-$svc.plist" "$trash/"
  done
  echo "plists moved to $trash" >"$trash/NOTE.md"
  say "removing firewall allow rule (sudo)"
  remove_pf
  echo "done. Start by hand again with: $VOICE_DIR/run.sh start"
  exit 0
fi

[ "$(uname -s)" = Darwin ] || { echo "run this on the Mac"; exit 1; }
[ -d "$VOICE_DIR" ] || { echo "no $VOICE_DIR; copy the mac-voice folder there first"; exit 1; }

if [ ! -x "$PY" ]; then
  say "first-time setup (uv, Python 3.12, packages)"
  "$VOICE_DIR/run.sh" setup
fi

say "stopping copies started with run.sh"
"$VOICE_DIR/run.sh" stop || true
for svc in stt tts; do unload_agent "$svc"; done

mkdir -p "$AGENTS" "$VOICE_DIR/logs"
for svc in stt tts; do
  plist="$AGENTS/$LABEL_PREFIX-$svc.plist"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL_PREFIX-$svc</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$VOICE_DIR/${svc}_server.py</string>
  </array>
  <key>WorkingDirectory</key><string>$VOICE_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>VOICE_HOST</key><string>$VOICE_HOST</string>
    <key>STT_PORT</key><string>$STT_PORT</string>
    <key>TTS_PORT</key><string>$TTS_PORT</string>
    <key>TTS_MODEL</key><string>$TTS_MODEL</string>
    <key>TTS_VOICE</key><string>$TTS_VOICE</string>
    <key>TTS_FIRST_MAX_WORDS</key><string>$TTS_FIRST_MAX_WORDS</string>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$VOICE_DIR/logs/$svc.log</string>
  <key>StandardErrorPath</key><string>$VOICE_DIR/logs/$svc.log</string>
</dict>
</plist>
EOF
  plutil -lint "$plist" >/dev/null
  launchctl bootstrap "$DOMAIN" "$plist"
  launchctl enable "$DOMAIN/$LABEL_PREFIX-$svc"
  echo "$LABEL_PREFIX-$svc loaded"
done

say "letting Python accept connections through the macOS firewall (sudo)"
REAL_PY=$("$PY" -c 'import os, sys; print(os.path.realpath(sys.executable))')
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
sudo "$FW" --add "$REAL_PY" >/dev/null
sudo "$FW" --unblockapp "$REAL_PY" >/dev/null
echo "allowed: $REAL_PY"

if [ "$ALLOW_FROM" = any ]; then
  say "ALLOW_FROM=any: any LAN device can reach ports $STT_PORT and $TTS_PORT"
  remove_pf
else
  say "only $ALLOW_FROM (and this Mac) may connect to ports $STT_PORT/$TTS_PORT (sudo)"
  sudo mkdir -p /etc/pf.anchors
  sudo tee "$PF_ANCHOR_FILE" >/dev/null <<EOF
# Happy voice (STT $STT_PORT, TTS $TTS_PORT): this Mac and $ALLOW_FROM only.
pass in quick on lo0 proto tcp to any port { $STT_PORT $TTS_PORT }
pass in quick proto tcp from $ALLOW_FROM to any port { $STT_PORT $TTS_PORT }
block drop in quick proto tcp to any port { $STT_PORT $TTS_PORT }
EOF
  # The stock /etc/pf.conf evaluates anchor "com.apple/*", so a sub-anchor there needs no pf.conf edit.
  sudo tee "$PF_DAEMON" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.happy.voice-pf</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>/sbin/pfctl -E; /sbin/pfctl -a $PF_ANCHOR_NAME -f $PF_ANCHOR_FILE</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  sudo chown root:wheel "$PF_DAEMON" "$PF_ANCHOR_FILE"
  sudo chmod 644 "$PF_DAEMON" "$PF_ANCHOR_FILE"
  sudo launchctl bootout system "$PF_DAEMON" 2>/dev/null || true
  sudo launchctl bootstrap system "$PF_DAEMON"
  sleep 1
  sudo pfctl -a "$PF_ANCHOR_NAME" -s rules 2>/dev/null
fi

say "waiting for the services"
for svc in stt tts; do
  port=$([ "$svc" = stt ] && echo "$STT_PORT" || echo "$TTS_PORT")
  printf '%s: ' "$svc"
  for _ in $(seq 1 180); do
    if out=$(curl -fsS "http://127.0.0.1:$port/health" 2>/dev/null); then echo "$out"; continue 2; fi
    sleep 1
  done
  echo "not up yet; see $VOICE_DIR/logs/$svc.log"
done

IP=$(ipconfig getifaddr en0 2>/dev/null || true)
say "installed"
echo "STT  http://${IP:-<mac-ip>}:$STT_PORT   (ws://${IP:-<mac-ip>}:$STT_PORT/v1/stream)"
echo "TTS  http://${IP:-<mac-ip>}:$TTS_PORT"
echo "restart:  launchctl kickstart -k $DOMAIN/$LABEL_PREFIX-stt   (or -tts)"
echo "logs:     tail -f $VOICE_DIR/logs/stt.log"
echo "remove:   $0 --uninstall"
