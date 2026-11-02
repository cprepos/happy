#!/bin/bash
set -euo pipefail
#
# Install happy-cli daemon as a macOS launchd user agent, or on Linux as a
# systemd user service.
#
# Usage:
#   ./install-service.sh           # macOS: install and start. Linux: install and enable, no start
#   ./install-service.sh uninstall # stop and remove
#
# Prerequisites:
#   - ~/happy/.node/bin/node exists (isolated Node.js); on Linux, node on PATH
#     or HAPPY_SERVICE_NODE=/path/to/node
#   - ~/happy/packages/happy-cli built
#   - ~/.happy/settings.json configured with serverUrl
#
# The daemon runs as your login user, restarts on crash, and starts on login
# (Linux: at boot, if lingering is on).
# Logs go to ~/happy/logs/daemon-stdout.log and daemon-stderr.log (Linux: the
# user journal).

# The daemon runs under launchd as `daemon start-sync`, not `daemon start`.
# `daemon start` always spawns a detached child and exits 0 (see the
# daemonSubcommand === 'start' branch in packages/happy-cli/src/index.ts) --
# `--foreground` is not parsed there at all. Under launchd that means the job
# exits cleanly the moment it has forked, launchd marks it finished, and
# KeepAlive never fires again for the real daemon: a crash then goes unnoticed
# until the next login. `start-sync` runs startDaemon() inline, so the launchd
# job *is* the daemon and KeepAlive works as intended.

# Linux: a systemd user service, also running `daemon start-sync` for the reason
# above. It runs dist/index.mjs directly: bin/happy.mjs would re-exec node with
# these same flags through execFileSync, leaving a wrapper as the main process.
#
# Restart=always, not on-failure, because of how the daemon upgrades itself. When
# dist/index.mjs changes on disk it spawns a detached `daemon start` and exits 0
# (the bundleReplaced branch in packages/happy-cli/src/daemon/run.ts), which
# on-failure would treat as a finished service. The cost is that `happy daemon
# stop` alone becomes a restart. To really stop it, `systemctl --user stop`, then
# `happy daemon stop`: systemctl signals only the main process, and after a
# self-upgrade that is the waiting shell below, not the daemon beside it.
#
# Restarting straight into start-sync would not work while that replacement is
# alive: start-sync exits 0 with "already running", so each RestartSec costs a
# node start and a new log file until StartLimit gives up and leaves nothing
# watching. So ExecStart first waits, cheaply, for whichever daemon holds the
# lock to exit, then execs into the daemon so it is the main process. The wait
# ignores a lock left by a dead process or a reused PID, including its own: the
# daemon keeps this shell's PID, and boot order can hand the next boot's shell
# the same one.
#
# The start limit is wide because a slow boot can fail for a while: the daemon
# stays up offline when the server refuses connections, but exits 1 on errors
# outside NETWORK_ERROR_CODES, such as EAI_AGAIN before DNS is up. 180 tries is
# about half an hour before the unit is left failed.
#
# ConditionPathExists: with no credentials the daemon cannot prompt under systemd
# and exits 0, which Restart=always would repeat. After `happy auth logout` the
# unit simply stays down instead.
install_linux_service() {
    local unit_name="happy-cli-daemon.service"
    local unit_dir="$HOME/.config/systemd/user"
    local unit="$unit_dir/$unit_name"
    local root="$HOME/happy"
    local trash_dir="$root/trash/$(date +%Y%m%d_%H%M%S)_happy-cli-daemon-service"

    trash_unit() {
        mkdir -p "$trash_dir"
        mv "$unit" "$trash_dir/"
        echo "$1" > "$trash_dir/NOTE.txt"
        echo "Moved the unit to $trash_dir"
    }

    if [ "${1:-}" = "uninstall" ]; then
        if [ ! -f "$unit" ]; then
            echo "$unit is not installed."
            exit 0
        fi
        systemctl --user disable "$unit_name" 2>/dev/null || true
        # With KillMode=process this signals only the unit's own main process:
        # sessions keep running, and a daemon started outside the unit is not
        # touched. Left active, the unit would keep restarting with no file behind it.
        if systemctl --user is-active --quiet "$unit_name"; then
            echo "Stopping $unit_name (its main process only; sessions keep running)..."
            systemctl --user stop "$unit_name"
        fi
        systemctl --user reset-failed "$unit_name" 2>/dev/null || true
        trash_unit "$unit_name removed by install-service.sh uninstall on $(date)."
        systemctl --user daemon-reload
        echo "Done. Service removed. A daemon started outside the unit, or by its self-upgrade, keeps running:"
        echo "  happy daemon status"
        exit 0
    fi

    # Sanity checks
    local node="${HAPPY_SERVICE_NODE:-$(command -v node || true)}"
    if [ -z "$node" ] || [ ! -x "$node" ]; then
        echo "Error: node not found. Put it on PATH or set HAPPY_SERVICE_NODE=/path/to/node."
        exit 1
    fi
    local entry="$root/packages/happy-cli/dist/index.mjs"
    if [ ! -f "$entry" ]; then
        echo "Error: $entry not found. Build happy-cli first."
        exit 1
    fi
    local home_dir="${HAPPY_HOME_DIR:-$HOME/.happy}"
    home_dir="${home_dir/#\~/$HOME}"
    # These go unquoted into ExecStart's shell line.
    local path_value
    for path_value in "$node" "$entry" "$home_dir"; do
        case "$path_value" in
            /*[!A-Za-z0-9_./+@:,=-]*|[!/]*)
                echo "Error: '$path_value' must be an absolute path without spaces or shell characters."
                exit 1
                ;;
        esac
    done

    # Environment, captured from this shell. Allow-list only, so CLAUDE* and any
    # token stay out of the unit. Environment= expands % but not $.
    local env_lines="" name value
    for name in PATH HAPPY_HOME_DIR HAPPY_SERVER_URL HAPPY_WEBAPP_URL \
                LD_LIBRARY_PATH HF_HOME CUDA_HOME CARGO_HOME RUSTUP_HOME; do
        value="${!name:-}"
        [ -n "$value" ] || continue
        if [ "$name" = "PATH" ]; then
            value="$(printf '%s' "$value" | awk 'BEGIN { RS = ":"; ORS = "" } !seen[$0]++ { print sep $0; sep = ":" }')"
        fi
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        value="${value//%/%%}"
        env_lines="$env_lines"$'\n'"Environment=\"$name=$value\""
    done

    local unit_text
    unit_text="$(cat << UNIT
[Unit]
Description=Happy CLI daemon (connects this machine to the Happy server, starts sessions)
After=default.target
StartLimitIntervalSec=3600
StartLimitBurst=180
ConditionPathExists=$home_dir/access.key

[Service]
Type=simple
WorkingDirectory=%h/happy
$env_lines

# Waits while another daemon holds the lock, then becomes the daemon. The reasons
# are in selfhost/cli-service/install-service.sh.
ExecStart=/bin/sh -c 'while p=\$\$(cat $home_dir/daemon.state.json.lock 2>/dev/null) && [ "\$\$p" != "\$\$\$\$" ] && grep -qs start-sync "/proc/\$\$p/cmdline"; do sleep 15; done; exec $node --no-warnings --no-deprecation $entry daemon start-sync'

# Exit 0 also covers the daemon replacing itself on upgrade.
Restart=always
RestartSec=10

TimeoutStopSec=30
# Not mixed: sessions are children of the daemon and must outlive a daemon restart.
KillMode=process
KillSignal=SIGTERM

StandardOutput=journal
StandardError=journal
SyslogIdentifier=happy-cli-daemon

[Install]
WantedBy=default.target
UNIT
)"

    mkdir -p "$unit_dir"
    if [ -f "$unit" ] && [ "$(cat "$unit")" = "$unit_text" ]; then
        echo "$unit is already up to date."
    else
        if [ -f "$unit" ]; then
            trash_unit "$unit_name replaced by a re-run of install-service.sh on $(date)."
        fi
        (umask 077 && printf '%s\n' "$unit_text" > "$unit")
        echo "Installed $unit"
    fi
    chmod 600 "$unit"

    # Enable only. A running daemon may have live sessions, so nothing is started.
    systemctl --user daemon-reload
    systemctl --user enable "$unit_name"
    echo "Enabled. It takes over at the next boot, or when you run:"
    echo "  systemctl --user start happy-cli-daemon"
    echo "If a daemon is already running, that start waits for it to exit and then takes over."

    if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" != "yes" ]; then
        echo ""
        echo "Warning: lingering is off, so this will not start at boot without a login."
        echo "  loginctl enable-linger $(id -un)"
    fi

    echo ""
    echo "Commands:"
    echo "  happy daemon status                     # check daemon status"
    echo "  systemctl --user status happy-cli-daemon"
    echo "  systemctl --user restart happy-cli-daemon  # after a self-upgrade, use 'happy daemon stop' instead"
    echo "  systemctl --user stop happy-cli-daemon     # then 'happy daemon stop'; on its own that only restarts it"
    echo "  journalctl --user -u happy-cli-daemon -f"
    echo "  $0 uninstall                            # disable and remove"
    exit 0
}

if [ "$(uname -s)" = "Linux" ]; then
    install_linux_service "${1:-}"
fi

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
