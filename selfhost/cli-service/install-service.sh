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

LABEL="com.happy.cli-daemon"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"
HAPPY_ROOT="$HOME/happy"
NODE="$HAPPY_ROOT/.node/bin/node"
HAPPY_BIN="$HAPPY_ROOT/packages/happy-cli/bin/happy.mjs"
LOG_DIR="$HAPPY_ROOT/logs"

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
        <string>start</string>
        <string>--foreground</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HAPPY_ROOT/.node/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
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

echo "Installed $PLIST"

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
