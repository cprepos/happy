#!/bin/bash
set -euo pipefail
#
# Install happy-cli daemon as a macOS launchd user agent.
#
# Usage:
#   ./install-service.sh           # install and start
#   ./install-service.sh uninstall # stop and remove
#
# Prerequisites:
#   - ~/happy/.node/bin/node exists (isolated Node.js)
#   - ~/happy/packages/happy-cli built
#   - ~/.happy/settings.json configured with serverUrl
#
# The daemon runs as your login user, restarts on crash, and starts on login.
# Logs go to ~/happy/logs/daemon-stdout.log and daemon-stderr.log.

# The daemon runs under launchd as `daemon start-sync`, not `daemon start`.
# `daemon start` always spawns a detached child and exits 0 (see the
# daemonSubcommand === 'start' branch in packages/happy-cli/src/index.ts) --
# `--foreground` is not parsed there at all. Under launchd that means the job
# exits cleanly the moment it has forked, launchd marks it finished, and
# KeepAlive never fires again for the real daemon: a crash then goes unnoticed
# until the next login. `start-sync` runs startDaemon() inline, so the launchd
# job *is* the daemon and KeepAlive works as intended.

LABEL="com.happy.cli-daemon"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"
HAPPY_ROOT="$HOME/happy"
# Prefer Homebrew node@24 (required by OpenClaw), fall back to isolated node
if [ -x /opt/homebrew/opt/node@24/bin/node ]; then
    NODE="/opt/homebrew/opt/node@24/bin/node"
else
    NODE="$HAPPY_ROOT/.node/bin/node"
fi
HAPPY_BIN="$HAPPY_ROOT/packages/happy-cli/bin/happy.mjs"
LOG_DIR="$HAPPY_ROOT/logs"

# OpenClaw gateway. Only hosts without a local OpenClaw install need these:
# runOpenClaw() resolves CLI args > env > ~/.openclaw/openclaw.json, so the
# machine running the gateway finds its own URL and token in that config and
# can leave both unset. Everywhere else, point at the gateway host.
#
# Read from selfhost/.env (gitignored, mode 600) when present, so the token is
# never written into a tracked file. Override by exporting either var before
# running this script.
SELFHOST_ENV="$HAPPY_ROOT/selfhost/.env"
if [ -f "$SELFHOST_ENV" ]; then
    OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-$(sed -n 's/^OPENCLAW_GATEWAY_URL=//p' "$SELFHOST_ENV" | tail -1)}"
    OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(sed -n 's/^OPENCLAW_GATEWAY_TOKEN=//p' "$SELFHOST_ENV" | tail -1)}"
fi
OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"

# Emit the two keys only when set, so a host with a local gateway config keeps
# using it rather than inheriting an empty override.
OPENCLAW_PLIST_ENV=""
if [ -n "$OPENCLAW_GATEWAY_URL" ]; then
    OPENCLAW_PLIST_ENV="        <key>OPENCLAW_GATEWAY_URL</key>
        <string>$OPENCLAW_GATEWAY_URL</string>"
fi
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    OPENCLAW_PLIST_ENV="$OPENCLAW_PLIST_ENV
        <key>OPENCLAW_GATEWAY_TOKEN</key>
        <string>$OPENCLAW_GATEWAY_TOKEN</string>"
fi

uninstall() {
    echo "Stopping and removing $LABEL..."
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Done. Daemon removed."
    exit 0
}

if [ "${1:-}" = "uninstall" ]; then
    uninstall
fi

# Sanity checks
if [ ! -x "$NODE" ]; then
    echo "Error: $NODE not found. Run the setup first (see selfhost/README.md)."
    exit 1
fi
if [ ! -f "$HAPPY_BIN" ]; then
    echo "Error: $HAPPY_BIN not found. Build happy-cli first."
    exit 1
fi

mkdir -p "$LOG_DIR" "$PLIST_DIR"

# Stop existing if loaded
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

cat > "$PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE</string>
        <string>$HAPPY_BIN</string>
        <string>daemon</string>
        <string>start-sync</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.local/openclaw-npm/bin:$HAPPY_ROOT/.node/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
$OPENCLAW_PLIST_ENV
    </dict>
    <key>WorkingDirectory</key>
    <string>$HAPPY_ROOT</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/daemon-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/daemon-stderr.log</string>
</dict>
</plist>
PLIST

# The plist can carry the gateway token, so keep it owner-readable only.
chmod 600 "$PLIST"

echo "Installed $PLIST"
if [ -n "$OPENCLAW_GATEWAY_URL" ]; then
    echo "OpenClaw gateway: $OPENCLAW_GATEWAY_URL (token ${OPENCLAW_GATEWAY_TOKEN:+set}${OPENCLAW_GATEWAY_TOKEN:-unset})"
else
    echo "OpenClaw gateway: not set; will fall back to ~/.openclaw/openclaw.json"
fi

# Load and start
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2

# Check status
if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
    echo "Daemon is running."
else
    echo "Daemon loaded. Check logs at $LOG_DIR/ if it doesn't start."
    echo "Status: launchctl print gui/$(id -u)/$LABEL"
fi

echo ""
echo "Commands:"
echo "  happy daemon status              # check daemon status"
echo "  launchctl kickstart -k gui/$(id -u)/$LABEL  # restart"
echo "  $0 uninstall                     # stop and remove"
echo ""
echo "Add to PATH (optional, for interactive use):"
echo "  echo 'export PATH=\"\$HOME/happy/.node/bin:\$PATH\"' >> ~/.zshrc"
