#!/bin/bash
# Double-click to install (or reinstall) Happy on this Mac:
#   - the ~/happy checkout (cloned from the fork's main if it isn't here yet)
#   - happy-cli, built and on PATH
#   - the Happy daemon as a login service: it starts on every login/restart
#     and relaunches itself if it crashes.
# Safe to re-run. Running chats survive it.
set -uo pipefail

HAPPY_ROOT="$HOME/happy"
REPO_URL="https://github.com/cprepos/happy.git"
SERVER_URL="https://happy.girthbass.duckdns.org"
NODE_VERSION="22.16.0"
BIN="$HAPPY_ROOT/.node/bin"
HAPPY="$BIN/happy"
LABEL="com.happy.cli-daemon"
export PATH="$BIN:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

finish() { echo ""; read -n 1 -s -r -p "Press any key to close this window..."; echo; exit "${1:-0}"; }

echo "==> Happy installer ($(scutil --get ComputerName 2>/dev/null || hostname))"
echo ""

# 0. git needs the Command Line Tools. Installing them asks for your password.
if ! xcode-select -p >/dev/null 2>&1; then
    echo "==> The Command Line Tools are missing. A window will ask to install them."
    echo "    Finish that install, then double-click this file again."
    xcode-select --install
    finish 1
fi

# 1. The checkout: clone if missing; otherwise fast-forward a clean main.
if [ ! -d "$HAPPY_ROOT/.git" ]; then
    echo "==> Cloning $REPO_URL into $HAPPY_ROOT..."
    git clone -b main "$REPO_URL" "$HAPPY_ROOT" || { echo "Clone failed."; finish 1; }
else
    cd "$HAPPY_ROOT" || finish 1
    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$branch" != "main" ]; then
        echo "Stopped: $HAPPY_ROOT is on '$branch', not main. Nothing was changed."
        finish 1
    fi
    if [ -n "$(git status --short --untracked-files=no)" ]; then
        git status --short --untracked-files=no
        echo "Stopped: the checkout has local changes. Nothing was changed."
        finish 1
    fi
    echo "==> Updating the checkout from the fork's main..."
    git fetch "$REPO_URL" main || { echo "Stopped: fetch failed. Nothing was changed."; finish 1; }
    if git merge-base --is-ancestor FETCH_HEAD HEAD; then
        echo "    Already has everything on the fork's main."
    else
        git merge --ff-only FETCH_HEAD || { echo "Stopped: can't fast-forward. Nothing was changed."; finish 1; }
    fi
fi
cd "$HAPPY_ROOT" || finish 1
echo "    At: $(git log --oneline -1)"

# 2. Isolated Node.js in ~/happy/.node (no system install).
if [ ! -x "$BIN/node" ]; then
    case "$(uname -m)" in
        arm64) node_arch="arm64" ;;
        x86_64) node_arch="x64" ;;
        *) echo "Unsupported CPU: $(uname -m)"; finish 1 ;;
    esac
    echo ""
    echo "==> Installing Node.js v$NODE_VERSION ($node_arch) into $HAPPY_ROOT/.node..."
    mkdir -p "$HAPPY_ROOT/.node"
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-$node_arch.tar.xz" \
        | tar -xJ --strip-components=1 -C "$HAPPY_ROOT/.node/" || { echo "Node download failed."; finish 1; }
fi
echo "    node $("$BIN/node" --version)"

# 3. pnpm, dependencies, builds.
echo ""
echo "==> Installing dependencies (first run takes a while)..."
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
"$BIN/corepack" enable --install-directory "$BIN" pnpm || { echo "corepack failed."; finish 1; }
pnpm install --frozen-lockfile || { echo "pnpm install failed."; finish 1; }

cli_dist="$HAPPY_ROOT/packages/happy-cli/dist"
dist_backup=""
if [ -d "$cli_dist" ]; then
    dist_backup="$HAPPY_ROOT/trash/$(date +%Y%m%d_%H%M%S)_cli_dist_before_install"
    mkdir -p "$dist_backup"
    cp -a "$cli_dist" "$dist_backup/dist" || { echo "Backing up the old build failed. Nothing was rebuilt."; finish 1; }
    echo "CLI dist before an install, kept for rollback." > "$dist_backup/NOTE.txt"
    echo "    Old build backed up to $dist_backup"
fi

echo ""
echo "==> Building happy-cli..."
pnpm --filter happy build
cli_build_rc=$?
# Running chats can still load chunks from the old build. This never overwrites new files.
if [ -n "$dist_backup" ]; then
    mkdir -p "$cli_dist"
    cp -an "$dist_backup/dist/." "$cli_dist/" 2>/dev/null
fi
[ "$cli_build_rc" -eq 0 ] || { echo "happy-cli build failed."; finish 1; }

# 4. Command wrappers in ~/happy/.node/bin.
cat > "$HAPPY" << 'WRAPPER'
#!/bin/sh
HAPPY_ROOT="$HOME/happy"
export PATH="$HOME/.local/openclaw-npm/bin:$HAPPY_ROOT/.node/bin:/opt/homebrew/bin:$PATH"
# Prefer Homebrew node@24 (required by OpenClaw), fall back to isolated node
NODE="$(command -v /opt/homebrew/opt/node@24/bin/node 2>/dev/null || echo "$HAPPY_ROOT/.node/bin/node")"
exec "$NODE" "$HAPPY_ROOT/packages/happy-cli/bin/happy.mjs" "$@"
WRAPPER
# The remote-control happy-agent CLI is gone (upstream removed
# packages/happy-agent). A wrapper left by an older install would point at a
# missing file, so it goes to the trash, never deleted.
if [ -e "$BIN/happy-agent" ]; then
    trash_dir="$HAPPY_ROOT/trash/$(date +%Y%m%d_%H%M%S)_happy-agent-wrapper"
    mkdir -p "$trash_dir" && mv "$BIN/happy-agent" "$trash_dir/" && echo "    Moved the old happy-agent wrapper to $trash_dir"
fi
chmod +x "$HAPPY"

# Put the commands on PATH for new Terminal windows.
if ! grep -qs 'happy/.node/bin' "$HOME/.zshrc"; then
    echo 'export PATH="$HOME/happy/.node/bin:$PATH"' >> "$HOME/.zshrc"
    echo "    Added ~/happy/.node/bin to PATH in ~/.zshrc"
fi

# 5. Server settings, only if this Mac has none (keeps its machineId).
if [ ! -f "$HOME/.happy/settings.json" ]; then
    mkdir -p "$HOME/.happy"
    cat > "$HOME/.happy/settings.json" << EOF
{
  "schemaVersion": 2,
  "onboardingCompleted": false,
  "serverUrl": "$SERVER_URL",
  "webappUrl": "$SERVER_URL"
}
EOF
    echo "    Wrote ~/.happy/settings.json (server $SERVER_URL)"
fi
echo ""
echo "    $("$HAPPY" --version 2>&1 | head -1)"

# 6. Link this Mac (daemon) to your account if it isn't yet.
if [ ! -f "$HOME/.happy/access.key" ]; then
    echo ""
    echo "==> This Mac is not linked yet. Choose 'Mobile App' and scan the QR code."
    "$HAPPY" auth login || { echo "Linking failed."; finish 1; }
fi
if [ ! -f "$HOME/.happy/access.key" ]; then
    echo "Still not linked; stopping."
    finish 1
fi

# 7. Stop the old service and any stray daemons that hold the lock.
#    Chats are separate processes and keep running.
echo ""
echo "==> Stopping any running Happy daemon..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
"$HAPPY" daemon stop >/dev/null 2>&1 || true
pkill -f "happy-cli/dist/index.mjs daemon" 2>/dev/null || true
sleep 2
pkill -9 -f "happy-cli/dist/index.mjs daemon" 2>/dev/null || true
rm -f "$HOME/.happy/daemon.state.json.lock"

# 8. Install the launchd agent (RunAtLoad + KeepAlive).
echo ""
bash "$HAPPY_ROOT/selfhost/cli-service/install-service.sh" || { echo "Install failed."; finish 1; }

# 9. Verify.
echo ""
echo "==> Checking..."
sleep 5
if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
    echo "OK: the Happy service is running and will start again after every restart."
else
    echo "The service did not come up. Last log lines:"
    tail -20 "$HAPPY_ROOT/logs/daemon-stderr.log" 2>/dev/null
    finish 1
fi
"$HAPPY" daemon status 2>&1 | head -8
finish 0
