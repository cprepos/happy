#!/usr/bin/env bash
# Build and install the self-hosted iOS app on your own iPhone (or a simulator)
# from an Apple Silicon Mac, signed with a personal Apple team.
#
# Usage: selfhost/ios/build.sh [--simulator] [--debug] [--skip-prebuild]
#                              [--no-build-cache] [--device NAME|UDID] [-h]
#
# Config: selfhost/ios/.env.ios (copy from .env.ios.example).
#
# Env contract consumed by packages/happy-app/app.config.js (SELFHOST mode):
#   SELFHOST=1, APP_BUNDLE_ID_PREFIX, APP_DISPLAY_NAME, SELFHOST_SERVER_URL,
#   EXPO_PUBLIC_HAPPY_SERVER_URL, EXPO_PUBLIC_SERVER_URL,
#   EXPO_PUBLIC_DISABLE_ANALYTICS=1, APP_ENV.
# In SELFHOST mode the config drops push (aps-environment), associated
# domains, in-app purchases and EAS updates, none of which a personal team
# can sign. This script verifies that after prebuild.
set -euo pipefail

MIN_XCODE="16.1"        # Expo SDK 55 / React Native 0.83 minimum
MIN_NODE="20.19.4"      # React Native 0.83 minimum
PNPM_VERSION="10.11"    # packageManager in root package.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$REPO_ROOT/packages/happy-app"
ENV_FILE="$SCRIPT_DIR/.env.ios"
TS="$(date +%Y%m%d_%H%M%S)"

SIMULATOR=0
DEBUG=0
SKIP_PREBUILD=0
NO_BUILD_CACHE=0
DEVICE_ARG=""

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_bld=$'\033[1m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_ylw=""; c_bld=""; c_off=""; }
step() { printf '\n%s==> %s%s\n' "$c_bld" "$*" "$c_off"; }
ok()   { printf '  %sok%s   %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '  %swarn%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() {
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --simulator        Build for the iOS Simulator (no signing team needed).
  --debug            Debug build: dev client + Metro bundler (live reload).
                     Default is a Release build with the JS bundle embedded,
                     which runs without the Mac.
  --skip-prebuild    Reuse the existing packages/happy-app/ios project
                     (fast rebuild after JS-only changes).
  --no-build-cache   Clear Xcode derived data before building.
  --device X         Device name or UDID (overrides DEVICE in .env.ios).
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --simulator) SIMULATOR=1 ;;
        --debug) DEBUG=1 ;;
        --skip-prebuild) SKIP_PREBUILD=1 ;;
        --no-build-cache) NO_BUILD_CACHE=1 ;;
        --device) [[ $# -ge 2 ]] || die "--device needs a value"; DEVICE_ARG="$2"; shift ;;
        --device=*) DEVICE_ARG="${1#--device=}" ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

# version_ge A B: true if dotted version A >= B
version_ge() {
    local IFS=.
    # shellcheck disable=SC2206
    local a=($1) b=($2) i
    for i in 0 1 2; do
        local x="${a[i]:-0}" y="${b[i]:-0}"
        x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
        (( 10#${x:-0} > 10#${y:-0} )) && return 0
        (( 10#${x:-0} < 10#${y:-0} )) && return 1
    done
    return 0
}

# corepack resolves pnpm from the root package.json, so work from the repo root.
cd "$REPO_ROOT"

# ---------------------------------------------------------------- preflight
step "Preflight"

[[ "$(uname -s)" == "Darwin" ]] || die "this script runs on macOS only."
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) Mac required; found $(uname -m). If this is a Rosetta shell, open a native Terminal."
ok "macOS $(sw_vers -productVersion) on arm64"

command -v xcodebuild >/dev/null 2>&1 || die "Xcode not found. Install Xcode $MIN_XCODE+ (Xcode 26 recommended) from the App Store, open it once, then run: sudo xcodebuild -license accept"
XCODE_DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$XCODE_DEV_DIR" != *".app/Contents/Developer" ]]; then
    die "xcode-select points at '${XCODE_DEV_DIR:-nothing}', not a full Xcode. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | awk '/^Xcode/{print $2; exit}')" \
    || die "xcodebuild failed. Accept the license: sudo xcodebuild -license accept"
[[ -n "$XCODE_VERSION" ]] || die "could not read Xcode version (try: sudo xcodebuild -license accept; xcodebuild -runFirstLaunch)"
version_ge "$XCODE_VERSION" "$MIN_XCODE" || die "Xcode $XCODE_VERSION is too old; Expo SDK 55 / React Native 0.83 need Xcode $MIN_XCODE+ (Xcode 26 recommended)."
ok "Xcode $XCODE_VERSION ($XCODE_DEV_DIR)"
if [[ $SIMULATOR -eq 1 ]]; then
    xcrun simctl list runtimes 2>/dev/null | grep -q '^iOS' \
        || die "no iOS Simulator runtime installed. Xcode > Settings > Components > iOS, or: xcodebuild -downloadPlatform iOS"
fi

command -v git >/dev/null 2>&1 || die "git not found (it ships with Xcode command line tools)."
ok "git $(git --version | awk '{print $3}')"

if ! command -v pod >/dev/null 2>&1; then
    die "CocoaPods not found. Install with: brew install cocoapods   (or: sudo gem install cocoapods)"
fi
ok "CocoaPods $(pod --version)"

if ! command -v node >/dev/null 2>&1; then
    die "Node.js not found. Install Node $MIN_NODE+ (22 LTS recommended), e.g.:
    brew install fnm && fnm install 22 && fnm use 22
  or nvm: nvm install 22 && nvm use 22"
fi
NODE_VERSION="$(node -p 'process.versions.node')"
version_ge "$NODE_VERSION" "$MIN_NODE" || die "Node $NODE_VERSION is too old; need $MIN_NODE+ (try: fnm install 22 / nvm install 22)."
ok "Node $NODE_VERSION"

if ! command -v pnpm >/dev/null 2>&1 || [[ "$(pnpm --version 2>/dev/null)" != "$PNPM_VERSION".* ]]; then
    if command -v corepack >/dev/null 2>&1; then
        warn "pnpm $PNPM_VERSION not active; enabling via corepack"
        corepack enable >/dev/null 2>&1 || die "corepack enable failed (with a Homebrew Node try: corepack enable --install-directory ~/.local/bin and add it to PATH)"
        corepack prepare "pnpm@${PNPM_VERSION}.0" --activate >/dev/null
    else
        die "pnpm $PNPM_VERSION required. Run: npm install -g corepack && corepack enable"
    fi
fi
PNPM_FOUND="$(pnpm --version 2>/dev/null || true)"
[[ "$PNPM_FOUND" == "$PNPM_VERSION".* ]] || die "pnpm is '${PNPM_FOUND:-missing}', expected $PNPM_VERSION.x (corepack prepare pnpm@${PNPM_VERSION}.0 --activate)"
ok "pnpm $PNPM_FOUND"

# ------------------------------------------------------------------- config
step "Config ($ENV_FILE)"
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE. Run: cp $SCRIPT_DIR/.env.ios.example $ENV_FILE and edit it."
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APP_BUNDLE_ID_PREFIX="${APP_BUNDLE_ID_PREFIX:-}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Happy Self}"
HAPPY_PUBLIC_URL="${HAPPY_PUBLIC_URL:-https://happy.girthbass.duckdns.org}"
HAPPY_PUBLIC_URL="${HAPPY_PUBLIC_URL%/}"
APP_ENV="${APP_ENV:-preview}"
DEVICE="${DEVICE_ARG:-${DEVICE:-}}"

case "$APP_ENV" in development|preview|production) ;; *) die "APP_ENV must be development, preview or production (got '$APP_ENV')";; esac
[[ -n "$APP_BUNDLE_ID_PREFIX" ]] || die "APP_BUNDLE_ID_PREFIX is empty in $ENV_FILE"
[[ "$APP_BUNDLE_ID_PREFIX" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "APP_BUNDLE_ID_PREFIX '$APP_BUNDLE_ID_PREFIX' is not reverse-DNS (letters, digits, '-', dots)"
case "$APP_BUNDLE_ID_PREFIX" in com.slopus.*|com.ex3ndr.*|com.slopus|com.ex3ndr)
    die "APP_BUNDLE_ID_PREFIX must be your own; '$APP_BUNDLE_ID_PREFIX' belongs to the upstream app";; esac
[[ "$HAPPY_PUBLIC_URL" =~ ^https?:// ]] || die "HAPPY_PUBLIC_URL must start with https:// (got '$HAPPY_PUBLIC_URL')"
if [[ $SIMULATOR -eq 0 ]]; then
    [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "APPLE_TEAM_ID must be the 10-character team ID (got '${APPLE_TEAM_ID}'). See README: Apple ID setup."
fi
ok "team=${APPLE_TEAM_ID:-<none>} prefix=$APP_BUNDLE_ID_PREFIX name='$APP_DISPLAY_NAME' env=$APP_ENV"
ok "server=$HAPPY_PUBLIC_URL"

if curl -fsS -m 10 -o /dev/null "$HAPPY_PUBLIC_URL" 2>/dev/null; then
    ok "server reachable"
else
    warn "could not reach $HAPPY_PUBLIC_URL from this Mac (continuing; the app needs it at runtime)"
fi

# Target device
if [[ $SIMULATOR -eq 0 ]]; then
    DEVICES="$(xcrun xctrace list devices 2>/dev/null | awk '/^== Devices ==/{f=1;next} /^== /{f=0} f' | grep -E '\(([0-9A-Fa-f-]{25}|[0-9a-f]{40})\)$' || true)"
    if [[ -z "$DEVICES" ]]; then
        die "no iPhone connected. Plug it in by USB, unlock it, tap Trust, and enable Developer Mode (Settings > Privacy & Security > Developer Mode). Or use --simulator."
    fi
    ok "connected devices:"; printf '         %s\n' "$DEVICES"
    if [[ -n "$DEVICE" ]] && ! grep -qF -- "$DEVICE" <<<"$DEVICES"; then
        warn "DEVICE '$DEVICE' not in the connected list above; expo will try anyway"
    fi
fi

# ------------------------------------------------------------- env contract
export SELFHOST=1
export APP_ENV APP_BUNDLE_ID_PREFIX APP_DISPLAY_NAME
export SELFHOST_SERVER_URL="$HAPPY_PUBLIC_URL"
export EXPO_PUBLIC_HAPPY_SERVER_URL="$HAPPY_PUBLIC_URL"
export EXPO_PUBLIC_SERVER_URL="$HAPPY_PUBLIC_URL"
export EXPO_PUBLIC_DISABLE_ANALYTICS=1
# Keys for hosted third-party services are never baked into a self-host build.
unset EXPO_PUBLIC_POSTHOG_API_KEY EXPO_PUBLIC_REVENUE_CAT_APPLE \
      EXPO_PUBLIC_REVENUE_CAT_GOOGLE EXPO_PUBLIC_REVENUE_CAT_STRIPE || true
# Expo prebuild otherwise prompts when the git tree is dirty.
export EXPO_NO_GIT_STATUS=1
export EXPO_NO_TELEMETRY=1
# app.config.js reads git metadata; pin it so the build does not depend on cwd.
HAPPY_BUILD_COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
HAPPY_BUILD_COMMIT_TIMESTAMP="$(git -C "$REPO_ROOT" show -s --format=%cI HEAD 2>/dev/null || true)"
export HAPPY_BUILD_COMMIT_SHA HAPPY_BUILD_COMMIT_TIMESTAMP

# ------------------------------------------------------------------ install
step "pnpm install --frozen-lockfile"
pnpm install --frozen-lockfile

# ----------------------------------------------------- resolved config check
step "Checking resolved app config (SELFHOST mode)"
grep -q 'SELFHOST' "$APP_DIR/app.config.js" \
    || die "packages/happy-app/app.config.js has no SELFHOST support on this branch. Merge the self-host app config change first."
CONFIG_JSON="$(cd "$APP_DIR" && npx expo config --type prebuild --json 2>/dev/null)" \
    || die "'npx expo config' failed; run it in packages/happy-app to see the error."
BUNDLE_ID="$(node -e '
const c = JSON.parse(require("fs").readFileSync(0, "utf8"));
const ios = c.ios || {}; const problems = [];
if (!ios.bundleIdentifier || !ios.bundleIdentifier.startsWith(process.argv[1])) problems.push("bundleIdentifier " + ios.bundleIdentifier + " does not start with " + process.argv[1]);
if (ios.associatedDomains && ios.associatedDomains.length) problems.push("associatedDomains still set");
if (ios.entitlements && ios.entitlements["aps-environment"]) problems.push("aps-environment still set");
if (c.updates && c.updates.url) problems.push("EAS updates url still set");
if (problems.length) { console.error(problems.join("\n")); process.exit(1); }
process.stdout.write(ios.bundleIdentifier + "\t" + c.name);
' "$APP_BUNDLE_ID_PREFIX" <<<"$CONFIG_JSON")" || die "app config is not in self-host shape (see above)."
ok "bundle id: ${BUNDLE_ID%%$'\t'*}"
ok "name:      ${BUNDLE_ID#*$'\t'}"

# ----------------------------------------------------------------- prebuild
IOS_DIR="$APP_DIR/ios"
if [[ $SKIP_PREBUILD -eq 1 ]]; then
    [[ -d "$IOS_DIR" ]] || die "--skip-prebuild given but $IOS_DIR does not exist"
    step "Skipping prebuild (reusing $IOS_DIR)"
else
    if [[ -e "$IOS_DIR" ]]; then
        TRASH_DIR="$REPO_ROOT/trash/${TS}_ios_prebuild"
        step "Moving existing ios/ to $TRASH_DIR"
        mkdir -p "$TRASH_DIR"
        mv "$IOS_DIR" "$TRASH_DIR/ios"
        printf 'Moved %s here before a clean expo prebuild (selfhost/ios/build.sh, %s).\nSafe to delete once the new build works.\n' \
            "$IOS_DIR" "$TS" > "$TRASH_DIR/README.txt"
        ok "moved"
    fi
    step "npx expo prebuild -p ios --clean"
    (cd "$APP_DIR" && npx expo prebuild -p ios --clean)
fi

# Xcode build phases run with a minimal PATH; point them at this node
# (needed with nvm/fnm installs).
printf 'export NODE_BINARY=%q\n' "$(command -v node)" > "$IOS_DIR/.xcode.env.local"

# ------------------------------------------------------------------ signing
PBXPROJ="$(find "$IOS_DIR" -maxdepth 2 -path '*/Pods' -prune -o -name project.pbxproj -print | head -n1)"
[[ -n "$PBXPROJ" && -f "$PBXPROJ" ]] || die "no project.pbxproj under $IOS_DIR"
if [[ $SIMULATOR -eq 0 ]]; then
    step "Setting DEVELOPMENT_TEAM=$APPLE_TEAM_ID"
    cp "$PBXPROJ" "$PBXPROJ.pre-team.bak"
    # Replace any existing team, then add it next to each PRODUCT_BUNDLE_IDENTIFIER
    # (one per app-target build configuration).
    perl -0pi -e '
        s/^[ \t]*DEVELOPMENT_TEAM = [^;]*;\n//mg;
        s/^[ \t]*CODE_SIGN_STYLE = [^;]*;\n//mg;
        s/^([ \t]*)(PRODUCT_BUNDLE_IDENTIFIER = [^;]*;)$/$1CODE_SIGN_STYLE = Automatic;\n$1DEVELOPMENT_TEAM = '"$APPLE_TEAM_ID"';\n$1$2/mg;
    ' "$PBXPROJ"
    count="$(grep -c "DEVELOPMENT_TEAM = $APPLE_TEAM_ID;" "$PBXPROJ" || true)"
    [[ "$count" -ge 1 ]] || die "failed to set DEVELOPMENT_TEAM in $PBXPROJ (original kept at $PBXPROJ.pre-team.bak)"
    ok "set in $count build configuration(s) of $(basename "$(dirname "$PBXPROJ")")"
fi

# --------------------------------------------------------- entitlements check
step "Checking entitlements"
shopt -s nullglob
ENT_FILES=("$IOS_DIR"/*/*.entitlements)
shopt -u nullglob
bad=0
for f in "${ENT_FILES[@]}"; do
    for key in aps-environment com.apple.developer.associated-domains com.apple.developer.in-app-payments; do
        if grep -q "<key>$key</key>" "$f"; then
            printf '  %sFAIL%s %s contains %s\n' "$c_red" "$c_off" "${f#"$REPO_ROOT"/}" "$key" >&2
            bad=1
        fi
    done
    ok "${f#"$REPO_ROOT"/}"
done
if [[ $bad -ne 0 ]]; then
    die "the generated entitlements contain capabilities a personal Apple team cannot sign
(push / associated domains / in-app purchase). SELFHOST=1 in app.config.js should strip
them. Check that the self-host app config change is on this branch, then rerun without --skip-prebuild."
fi
[[ ${#ENT_FILES[@]} -gt 0 ]] || ok "no entitlements files (nothing to strip)"

# -------------------------------------------------------------------- build
CONFIGURATION=Release
if [[ $DEBUG -eq 1 ]]; then CONFIGURATION=Debug; fi
RUN_ARGS=(--configuration "$CONFIGURATION")
if [[ $DEBUG -eq 0 ]]; then RUN_ARGS+=(--no-bundler); fi
if [[ $NO_BUILD_CACHE -eq 1 ]]; then RUN_ARGS+=(--no-build-cache); fi
if [[ -n "$DEVICE" ]]; then
    RUN_ARGS+=(--device "$DEVICE")
elif [[ $SIMULATOR -eq 0 ]]; then
    RUN_ARGS+=(--device)   # last, without a value: interactive picker of connected devices
fi

step "npx expo run:ios ${RUN_ARGS[*]}"
cd "$APP_DIR"
npx expo run:ios "${RUN_ARGS[@]}"

step "Done"
if [[ $SIMULATOR -eq 0 ]]; then
    cat <<EOF
If iOS says "Untrusted Developer": Settings > General > VPN & Device Management >
your Apple ID > Trust. Free Apple IDs: the app stops launching after 7 days;
rerun this script (add --skip-prebuild for a faster rebuild) to refresh it.
EOF
fi
