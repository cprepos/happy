#!/bin/bash
set -euo pipefail
#
# Bootstrap happy-cli on a Mac from scratch.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cprepos/happy/selfhost/selfhost/cli-service/setup.sh | bash
#   # or:
#   ./setup.sh
#   ./setup.sh --server https://your-server.example.com
#
# What it does:
#   1. Clones the repo to ~/happy (or pulls if it exists)
#   2. Downloads Node.js 22 LTS into ~/happy/.node/ (no system install)
#   3. Installs pnpm, dependencies, builds happy-cli
#   4. Creates the `happy` wrapper in ~/happy/.node/bin/
#   5. Writes ~/.happy/settings.json with the server URL
#   6. Tells you to run install-service.sh to make it a daemon

SERVER_URL="https://happy.girthbass.duckdns.org"
NODE_VERSION="22.16.0"
HAPPY_ROOT="$HOME/happy"
REPO_URL="https://github.com/cprepos/happy.git"
BRANCH="selfhost"

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER_URL="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "==> Setting up happy-cli"
echo "    Server: $SERVER_URL"
echo "    Node:   v$NODE_VERSION"
echo "    Root:   $HAPPY_ROOT"
echo ""

# 1. Clone or update
if [ -d "$HAPPY_ROOT/.git" ]; then
    echo "==> Updating existing repo..."
    cd "$HAPPY_ROOT"
    git fetch origin
    git checkout "$BRANCH"
    git pull origin "$BRANCH"
else
    echo "==> Cloning repo..."
    git clone -b "$BRANCH" "$REPO_URL" "$HAPPY_ROOT"
    cd "$HAPPY_ROOT"
fi

# 2. Isolated Node.js
if [ -x "$HAPPY_ROOT/.node/bin/node" ]; then
    CURRENT=$("$HAPPY_ROOT/.node/bin/node" --version 2>/dev/null || echo "")
    if [ "$CURRENT" = "v$NODE_VERSION" ]; then
        echo "==> Node.js v$NODE_VERSION already installed"
    else
        echo "==> Upgrading Node.js from $CURRENT to v$NODE_VERSION..."
        rm -rf "$HAPPY_ROOT/.node"
        mkdir -p "$HAPPY_ROOT/.node"
        curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-arm64.tar.xz" \
            | tar -xJ --strip-components=1 -C "$HAPPY_ROOT/.node/"
    fi
else
    echo "==> Installing Node.js v$NODE_VERSION..."
    mkdir -p "$HAPPY_ROOT/.node"
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-arm64.tar.xz" \
        | tar -xJ --strip-components=1 -C "$HAPPY_ROOT/.node/"
fi

export PATH="$HAPPY_ROOT/.node/bin:$PATH"
echo "    $(node --version)"

# 3. pnpm
echo "==> Enabling pnpm..."
corepack enable pnpm 2>/dev/null || true
corepack install 2>/dev/null || true

# 4. Install and build
echo "==> Installing dependencies..."
cd "$HAPPY_ROOT"
pnpm install --frozen-lockfile

echo "==> Building happy-cli..."
pnpm --filter happy build

# 5. Wrapper script
echo "==> Creating happy wrapper..."
cat > "$HAPPY_ROOT/.node/bin/happy" << 'WRAPPER'
#!/bin/sh
HAPPY_ROOT="$HOME/happy"
export PATH="$HAPPY_ROOT/.node/bin:$PATH"
exec "$HAPPY_ROOT/.node/bin/node" "$HAPPY_ROOT/packages/happy-cli/bin/happy.mjs" "$@"
WRAPPER
chmod +x "$HAPPY_ROOT/.node/bin/happy"

# 6. Settings
echo "==> Configuring server..."
mkdir -p "$HOME/.happy"
cat > "$HOME/.happy/settings.json" << EOF
{
  "schemaVersion": 2,
  "onboardingCompleted": false,
  "serverUrl": "$SERVER_URL",
  "webappUrl": "$SERVER_URL"
}
EOF

# 7. Verify
echo ""
echo "==> Verifying..."
"$HAPPY_ROOT/.node/bin/happy" --version 2>&1 | head -1

echo ""
echo "==> Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Add to PATH:  echo 'export PATH=\"\$HOME/happy/.node/bin:\$PATH\"' >> ~/.zshrc"
echo "  2. Authenticate:  happy  (follow the prompts)"
echo "  3. Install as service:  bash ~/happy/selfhost/cli-service/install-service.sh"
echo ""
