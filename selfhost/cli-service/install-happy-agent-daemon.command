#!/bin/bash
# Double-click to install (or update) the upstream Happy Agent daemon
# (github.com/slopus/happy-agent) as a login service on this Mac, set up the
# same way as on prep-ml:
#   - binary in ~/opt/happy-agent/happy-agent
#   - HAPPY_HOME_DIR=~/.local/share/happy-agent/.happy, a symlink to ~/.happy,
#     so it shares happy-cli's sign-in and keeps its data in ~/.happy/agent,
#     while its public "happy" folder lands in ~/.local/share/happy-agent/happy
#     instead of ~/happy (the git repo)
#   - launchd agent com.happy.agent-daemon running `happy-agent run`,
#     started at login and relaunched if it crashes
# It lets the Happy app's in-app browser open this Mac's localhost and LAN
# URLs without a VPN. Safe to re-run. No admin needed.
set -uo pipefail

VERSION="0.4.113"
REPO="slopus/happy-agent"
LABEL="com.happy.agent-daemon"
DEST="$HOME/opt/happy-agent"
BIN="$DEST/happy-agent"
AGENT_HOME="$HOME/.local/share/happy-agent"
HAPPY_HOME="$AGENT_HOME/.happy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/happy-agent"
TRASH="$HOME/happy/trash"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

finish() { echo ""; read -n 1 -s -r -p "Press any key to close this window..."; echo; exit "${1:-0}"; }

echo "==> Happy Agent daemon installer ($(scutil --get ComputerName 2>/dev/null || hostname)), v$VERSION"
echo ""

# 1. This Mac must already be linked by happy-cli (Install Happy Service.command).
if [ ! -f "$HOME/.happy/access.key" ] || [ ! -f "$HOME/.happy/settings.json" ]; then
    echo "Stopped: ~/.happy isn't set up. Run 'Install Happy Service.command' first."
    finish 1
fi
SERVER_URL="$(sed -n 's/.*"serverUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.happy/settings.json" | head -1)"
if [ -z "$SERVER_URL" ]; then
    echo "Stopped: no serverUrl in ~/.happy/settings.json."
    finish 1
fi
echo "    Server: $SERVER_URL"

# 2. Download and verify the release.
case "$(uname -m)" in
    arm64) asset_arch="darwin-arm64" ;;
    x86_64) asset_arch="darwin-x64" ;;
    *) echo "Unsupported CPU: $(uname -m)"; finish 1 ;;
esac
asset="happy-agent-$VERSION-$asset_arch.tar.gz"
base="https://github.com/$REPO/releases/download/v$VERSION"
tmp="$(mktemp -d)"
echo ""
echo "==> Downloading $asset..."
(cd "$tmp" && curl -fL# -o "$asset" "$base/$asset" && curl -fsSL -o "$asset.sha256" "$base/$asset.sha256") \
    || { echo "Download failed."; finish 1; }
(cd "$tmp" && shasum -a 256 -c "$asset.sha256") || { echo "Checksum mismatch; nothing installed."; finish 1; }
mkdir -p "$tmp/x" && tar -xzf "$tmp/$asset" -C "$tmp/x" || { echo "Unpack failed."; finish 1; }
new_bin="$tmp/x/happy-agent-$asset_arch"
[ -f "$new_bin" ] || { echo "The archive has no happy-agent-$asset_arch."; finish 1; }

# 3. Stop the running service before replacing its binary.
echo ""
echo "==> Stopping any running Happy Agent service..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 2

# 4. Install the binary, keeping the old one in ~/happy/trash.
mkdir -p "$DEST"
if [ -f "$BIN" ]; then
    mkdir -p "$TRASH"
    cp -p "$BIN" "$TRASH/happy-agent.backup.$(date +%Y%m%d_%H%M%S)" || { echo "Backup failed; nothing replaced."; finish 1; }
    echo "    Old binary backed up to $TRASH"
fi
cp "$new_bin" "$BIN.new" && chmod +x "$BIN.new" && mv -f "$BIN.new" "$BIN" || { echo "Install failed."; finish 1; }
xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
rm -rf "$tmp"
echo "    Installed $BIN"

# 5. Home directory: ~/.local/share/happy-agent/.happy -> ~/.happy
mkdir -p "$AGENT_HOME" "$LOG_DIR"
if [ -L "$HAPPY_HOME" ]; then
    :
elif [ -e "$HAPPY_HOME" ]; then
    echo "Stopped: $HAPPY_HOME exists and isn't a symlink to ~/.happy. Nothing else was changed."
    finish 1
else
    ln -s "$HOME/.happy" "$HAPPY_HOME"
fi

# 6. The launchd agent.
mkdir -p "$(dirname "$PLIST")"
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
        <string>$BIN</string>
        <string>run</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>$HOME/.local/bin:$HOME/.bun/bin:$HOME/happy/.node/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HAPPY_HOME_DIR</key>
        <string>$HAPPY_HOME</string>
        <key>HAPPY_SERVER_URL</key>
        <string>$SERVER_URL</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$AGENT_HOME</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
PLIST
chmod 600 "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST" || { echo "launchctl bootstrap failed."; finish 1; }

# 7. Verify.
echo ""
echo "==> Checking..."
sleep 8
if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
    echo "OK: Happy Agent is running and will start again after every restart."
    launchctl print "gui/$(id -u)/$LABEL" | grep -E '^[[:space:]]+pid =' | head -1
else
    echo "The service did not stay up. Last log lines:"
    tail -20 "$LOG_DIR/stderr.log" "$LOG_DIR/stdout.log" 2>/dev/null
    finish 1
fi
echo ""
echo "Logs: $LOG_DIR"
tail -5 "$LOG_DIR/stdout.log" 2>/dev/null
finish 0
