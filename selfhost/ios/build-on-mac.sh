#!/usr/bin/env bash
# Build the self-hosted Happy iOS app on the Mac and install it on the iPhone,
# driven from the Linux box in one command.
#
# Usage (from the Linux box, any checkout of this repo):
#   selfhost/ios/build-on-mac.sh                 sync + deps, build, install
#   selfhost/ios/build-on-mac.sh --sync-only     rsync + pnpm install only
#   selfhost/ios/build-on-mac.sh --build-only    prebuild + xcodebuild (no sync, no install)
#   selfhost/ios/build-on-mac.sh --install-only  install the last build on the iPhone
#
# Run with -h for all options. See selfhost/ios/BUILD-ON-MAC.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SELF_REL="selfhost/ios/build-on-mac.sh"
TS="$(date +%Y%m%d_%H%M%S)"

MAC_HOST="${MAC_HOST:-prep-air}"
REMOTE_DIR="${REMOTE_DIR:-happy-build}"            # relative to the Mac user's $HOME
NODE_FORMULA="${NODE_FORMULA:-node@24}"            # keg-only Homebrew Node LTS used for the build
MIN_XCODE="16.1"                                   # Expo SDK 55 / React Native 0.83

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_bld=$'\033[1m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_ylw=""; c_bld=""; c_off=""; }
step() { printf '\n%s==> %s%s\n' "$c_bld" "$*" "$c_off"; }
ok()   { printf '  %sok%s   %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '  %swarn%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() {
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --sync-only       rsync the working tree to the Mac and run pnpm install.
  --build-only      On the Mac: expo prebuild + Release xcodebuild. No sync, no install.
  --install-only    Install the last built .app on the iPhone (devicectl).
  --skip-prebuild   Reuse the Mac's existing packages/happy-app/ios (JS-only changes).
  --skip-deps       Skip pnpm install during sync.
  --device X        Device name, UDID or CoreDevice id (default: the only paired iPhone).
  --host H          ssh host of the Mac (default: $MAC_HOST or prep-air).
  -h, --help        Show this help.

Environment (Linux side, forwarded to the Mac; each overrides the Mac config file):
  APPLE_TEAM_ID / DEVELOPMENT_TEAM   10-character Apple team ID
  APP_BUNDLE_ID_PREFIX               reverse-DNS prefix, letters/digits only (default org.duckdns.girthbass)
  APP_DISPLAY_NAME                   home-screen name (default "Happy")
  APP_ENV                            development | preview | production (default preview)
  SELFHOST_SERVER_URL                server URL (default: PUBLIC_URL from selfhost/.env)
  DEVICE                             same as --device
  MAC_HOST, REMOTE_DIR               ssh host and remote directory (default ~/happy-build)

Mac config file (git-ignored, never synced or overwritten):
  ~/happy-build/selfhost/ios/.env.ios   KEY=value lines, e.g. APPLE_TEAM_ID=ABCDE12345
EOF
}

DO_SYNC=1; DO_BUILD=1; DO_INSTALL=1
SKIP_PREBUILD=0; SKIP_DEPS=0
MAC_STAGE=""
DEVICE_ARG="${DEVICE:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sync-only)    DO_SYNC=1; DO_BUILD=0; DO_INSTALL=0 ;;
        --build-only)   DO_SYNC=0; DO_BUILD=1; DO_INSTALL=0 ;;
        --install-only) DO_SYNC=0; DO_BUILD=0; DO_INSTALL=1 ;;
        --skip-prebuild) SKIP_PREBUILD=1 ;;
        --skip-deps)    SKIP_DEPS=1 ;;
        --device)       [[ $# -ge 2 ]] || die "--device needs a value"; DEVICE_ARG="$2"; shift ;;
        --device=*)     DEVICE_ARG="${1#--device=}" ;;
        --host)         [[ $# -ge 2 ]] || die "--host needs a value"; MAC_HOST="$2"; shift ;;
        --host=*)       MAC_HOST="${1#--host=}" ;;
        --mac-stage)    [[ $# -ge 2 ]] || die "--mac-stage needs a value"; MAC_STAGE="$2"; shift ;;  # internal
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

# ======================================================================
# Mac side. Invoked over ssh as: build-on-mac.sh --mac-stage deps|build|install
# ======================================================================

version_ge() {   # version_ge A B: dotted version A >= B
    local IFS=.
    # shellcheck disable=SC2206
    local a=($1) b=($2) i x y
    for i in 0 1 2; do
        x="${a[i]:-0}"; y="${b[i]:-0}"
        x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
        (( 10#${x:-0} > 10#${y:-0} )) && return 0
        (( 10#${x:-0} < 10#${y:-0} )) && return 1
    done
    return 0
}

mac_env() {
    [[ "$(uname -s)" == "Darwin" ]] || die "--mac-stage runs on macOS only"
    # Non-interactive ssh shells do not read ~/.zprofile, so set PATH here.
    local brew_prefix=/opt/homebrew
    [[ -x "$brew_prefix/bin/brew" ]] || die "Homebrew not found at $brew_prefix"
    local node_bin="$brew_prefix/opt/$NODE_FORMULA/bin"
    [[ -x "$node_bin/node" ]] || die "$NODE_FORMULA not installed on the Mac. Run: brew install $NODE_FORMULA cocoapods watchman"
    BUILD_HOME="$HOME/.happy-build"
    mkdir -p "$BUILD_HOME/bin"
    export PATH="$BUILD_HOME/bin:$node_bin:$brew_prefix/bin:$brew_prefix/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 EXPO_NO_TELEMETRY=1 EXPO_NO_GIT_STATUS=1 CI=1
    export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"   # CocoaPods needs UTF-8
    # pnpm comes from corepack, pinned by "packageManager" in package.json.
    corepack enable --install-directory "$BUILD_HOME/bin" pnpm >/dev/null \
        || die "corepack enable failed"
    APP_DIR="$REPO_ROOT/packages/happy-app"
    IOS_DIR="$APP_DIR/ios"
    DERIVED_DIR="$BUILD_HOME/DerivedData"
    LAST_APP_FILE="$BUILD_HOME/last-app-path"
    TRASH_ROOT="$HOME/happy-build-trash"
    cd "$REPO_ROOT"
}

mac_load_config() {
    # Precedence: values forwarded from Linux (HB_*) > .env.ios on the Mac > defaults.
    local cfg="$SCRIPT_DIR/.env.ios"
    if [[ -f "$cfg" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$cfg"
        set +a
        ok "config: $cfg"
    fi
    APPLE_TEAM_ID="${HB_APPLE_TEAM_ID:-${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}}"
    APP_BUNDLE_ID_PREFIX="${HB_APP_BUNDLE_ID_PREFIX:-${APP_BUNDLE_ID_PREFIX:-org.duckdns.girthbass}}"
    APP_DISPLAY_NAME="${HB_APP_DISPLAY_NAME:-${APP_DISPLAY_NAME:-Happy}}"
    APP_ENV="${HB_APP_ENV:-${APP_ENV:-preview}}"
    SERVER_URL="${HB_SERVER_URL:-${SELFHOST_SERVER_URL:-${HAPPY_PUBLIC_URL:-}}}"
    SERVER_URL="${SERVER_URL%/}"
    DEVICE="${DEVICE_ARG:-${DEVICE:-}}"
    case "$APP_ENV" in development|preview|production) ;;
        *) die "APP_ENV must be development, preview or production (got '$APP_ENV')" ;; esac
    # Same rule as packages/happy-app/plugins/selfHost.js (no hyphens).
    [[ "$APP_BUNDLE_ID_PREFIX" =~ ^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$ ]] \
        || die "APP_BUNDLE_ID_PREFIX '$APP_BUNDLE_ID_PREFIX' must be reverse-DNS, letters and digits only (e.g. org.duckdns.girthbass)"
    case "$APP_BUNDLE_ID_PREFIX" in com.slopus|com.slopus.*|com.ex3ndr|com.ex3ndr.*)
        die "APP_BUNDLE_ID_PREFIX must be your own, '$APP_BUNDLE_ID_PREFIX' belongs to the upstream app" ;; esac
    [[ "$SERVER_URL" =~ ^https?:// ]] || die "server URL missing or invalid ('$SERVER_URL'). Set SELFHOST_SERVER_URL."
}

mac_stage_deps() {
    step "pnpm install --frozen-lockfile (Mac)"
    ok "node $(node -v), pnpm $(pnpm --version)"
    pnpm install --frozen-lockfile
}

mac_check_xcode() {
    local dev_dir xver
    if [[ ! -d /Applications/Xcode.app ]] && ! ls -d /Applications/Xcode*.app >/dev/null 2>&1; then
        die "Xcode is not installed. Install it from the App Store, open it once, sign in to your Apple ID
(Xcode > Settings > Accounts), then on the Mac run:
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    sudo xcodebuild -license accept
    xcodebuild -runFirstLaunch"
    fi
    dev_dir="$(xcode-select -p 2>/dev/null || true)"
    [[ "$dev_dir" == *.app/Contents/Developer ]] \
        || die "xcode-select points at '${dev_dir:-nothing}', not Xcode. On the Mac run:
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    xver="$(xcodebuild -version 2>&1 | awk '/^Xcode/ && !v {v=$2} END {print v}')"
    [[ -n "$xver" ]] || die "xcodebuild did not run ($(xcodebuild -version 2>&1 | head -n1)). On the Mac run:
    sudo xcodebuild -license accept
    xcodebuild -runFirstLaunch"
    version_ge "$xver" "$MIN_XCODE" || die "Xcode $xver is too old, need $MIN_XCODE+"
    ok "Xcode $xver ($dev_dir)"
    command -v pod >/dev/null || die "CocoaPods missing. Run: brew install cocoapods"
    ok "CocoaPods $(pod --version)"
}

mac_require_team() {
    [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "Apple team ID missing or invalid ('${APPLE_TEAM_ID}').
Put APPLE_TEAM_ID=XXXXXXXXXX in ~/$REMOTE_DIR/selfhost/ios/.env.ios on the Mac,
or pass APPLE_TEAM_ID=... on the command line. See selfhost/ios/BUILD-ON-MAC.md (Team ID)."
}

mac_export_build_env() {
    export SELFHOST=1 APP_ENV APP_BUNDLE_ID_PREFIX APP_DISPLAY_NAME
    export SELFHOST_SERVER_URL="$SERVER_URL"
    export EXPO_PUBLIC_HAPPY_SERVER_URL="$SERVER_URL" EXPO_PUBLIC_SERVER_URL="$SERVER_URL"
    export EXPO_PUBLIC_DISABLE_ANALYTICS=1
    unset EXPO_PUBLIC_POSTHOG_API_KEY EXPO_PUBLIC_POSTHOG_KEY EXPO_PUBLIC_REVENUE_CAT_APPLE \
          EXPO_PUBLIC_REVENUE_CAT_GOOGLE EXPO_PUBLIC_REVENUE_CAT_STRIPE || true
    # No .git on the Mac copy; the Linux side forwards the commit.
    export HAPPY_BUILD_COMMIT_SHA="${HB_COMMIT_SHA:-unknown}"
    export HAPPY_BUILD_COMMIT_TIMESTAMP="${HB_COMMIT_TS:-}"
}

mac_stage_build() {
    step "Preflight (Mac)"
    mac_check_xcode
    mac_load_config
    mac_require_team
    mac_export_build_env
    ok "team=$APPLE_TEAM_ID prefix=$APP_BUNDLE_ID_PREFIX name='$APP_DISPLAY_NAME' env=$APP_ENV"
    ok "server=$SERVER_URL commit=${HAPPY_BUILD_COMMIT_SHA:0:12}"
    [[ -d "$REPO_ROOT/node_modules" ]] || die "no node_modules on the Mac. Run with --sync-only first."

    if [[ $SKIP_PREBUILD -eq 1 ]]; then
        [[ -d "$IOS_DIR" ]] || die "--skip-prebuild given but $IOS_DIR does not exist"
        step "Reusing existing $IOS_DIR"
    else
        if [[ -e "$IOS_DIR" ]]; then
            local t="$TRASH_ROOT/${TS}_ios_prebuild"
            step "Moving previous ios/ to $t"
            mkdir -p "$t"
            mv "$IOS_DIR" "$t/ios"
            # shellcheck disable=SC2016
            printf '# %s\n\nPrevious generated `packages/happy-app/ios` moved here by %s before a clean\n`expo prebuild`. Generated output only; safe to remove once the new build works.\n' \
                "${TS}_ios_prebuild" "$SELF_REL" > "$t/NOTE.md"
        fi
        step "expo prebuild --platform ios --clean"
        (cd "$APP_DIR" && npx expo prebuild --platform ios --clean)
    fi

    # Xcode build phases run with a minimal PATH; pin node.
    printf 'export NODE_BINARY=%q\n' "$(command -v node)" > "$IOS_DIR/.xcode.env.local"

    local ws scheme pbx
    ws="$(find "$IOS_DIR" -maxdepth 1 -name '*.xcworkspace' | head -n1)"
    [[ -n "$ws" ]] || die "no .xcworkspace in $IOS_DIR (did pod install fail?)"
    scheme="$(basename "$ws" .xcworkspace)"
    pbx="$IOS_DIR/$scheme.xcodeproj/project.pbxproj"
    [[ -f "$pbx" ]] || die "missing $pbx"

    # Current Xcode rejects pod targets below iOS 15 (older pods declare
    # 9.0-13.x), and expo-router's Swift uses iOS 16 APIs. Raise them to 16.0.
    local pods_pbx="$IOS_DIR/Pods/Pods.xcodeproj/project.pbxproj"
    if [[ -f "$pods_pbx" ]]; then
        perl -pi -e 's{(IPHONEOS_DEPLOYMENT_TARGET = )(\d+)(\.\d+)*;}{$1 . ($2 < 16 ? "16.0" : "$2$3") . ";"}ge' "$pbx"
        perl -pi -e 's{(IPHONEOS_DEPLOYMENT_TARGET = )(\d+)(\.\d+)*;}{$1 . ($2 < 16 ? "16.0" : "$2$3") . ";"}ge' "$pods_pbx"
        ok "app and pod deployment targets >= 16.0"
    fi

    # RevenueCat 5.x: Swift 6.4 synthesizes PaywallColor's memberwise
    # init(stringRepresentation:) and rejects the explicit one as a
    # redeclaration. An init in the type body stops the synthesis.
    local paywall_color="$IOS_DIR/Pods/RevenueCat/Sources/Paywalls/PaywallColor.swift"
    if [[ -f "$paywall_color" ]] && ! grep -q '_noMemberwise' "$paywall_color"; then
        perl -0pi -e 's{(\n    fileprivate var _underlyingColor: \(any Sendable\)\?\n)}{$1\n    private init(_noMemberwise stringRepresentation: String) {\n        self.stringRepresentation = stringRepresentation\n    }\n}' "$paywall_color"
        grep -q '_noMemberwise' "$paywall_color" || die "could not patch $paywall_color"
        ok "patched RevenueCat PaywallColor for Swift 6.4"
    fi

    step "Signing: automatic, team $APPLE_TEAM_ID"
    # Set team + automatic signing on every app-target build configuration
    # (each one carries a PRODUCT_BUNDLE_IDENTIFIER). Idempotent.
    perl -0pi -e '
        s/^[ \t]*DEVELOPMENT_TEAM = [^;]*;\n//mg;
        s/^[ \t]*CODE_SIGN_STYLE = [^;]*;\n//mg;
        s/^([ \t]*)(PRODUCT_BUNDLE_IDENTIFIER = [^;]*;)$/$1CODE_SIGN_STYLE = Automatic;\n$1DEVELOPMENT_TEAM = '"$APPLE_TEAM_ID"';\n$1$2/mg;
    ' "$pbx"
    grep -q "DEVELOPMENT_TEAM = $APPLE_TEAM_ID;" "$pbx" || die "could not set DEVELOPMENT_TEAM in $pbx"
    ok "$scheme.xcodeproj"

    step "Checking entitlements (personal teams cannot sign push / associated domains / IAP)"
    local f bad=0
    shopt -s nullglob
    for f in "$IOS_DIR"/*/*.entitlements; do
        for key in aps-environment com.apple.developer.associated-domains com.apple.developer.in-app-payments; do
            if grep -q "<key>$key</key>" "$f"; then warn "${f#"$REPO_ROOT"/} contains $key"; bad=1; fi
        done
        ok "${f#"$REPO_ROOT"/}"
    done
    shopt -u nullglob
    [[ $bad -eq 0 ]] || die "entitlements still contain capabilities a personal team cannot sign; SELFHOST=1 should strip them"

    step "xcodebuild Release for a physical iPhone"
    local log="$BUILD_HOME/xcodebuild-$TS.log"
    set +e
    xcodebuild \
        -workspace "$ws" -scheme "$scheme" -configuration Release \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED_DIR" \
        -allowProvisioningUpdates \
        build 2>&1 | tee "$log" | grep -E --line-buffered '^(\*\*|error:|.*: error:|warning: .*(sign|provision))|Signing Identity|Provisioning Profile'
    local rc="${PIPESTATUS[0]}"
    set -e
    if [[ "$rc" -ne 0 ]]; then
        if grep -q 'errSecInternalComponent' "$log"; then
            die "codesign could not use the login keychain over ssh (errSecInternalComponent).
Either run the build once in Terminal on the Mac:   bash ~/$REMOTE_DIR/$SELF_REL --build-only
and click 'Always Allow' when codesign asks, or unlock the keychain for ssh sessions:
    security unlock-keychain ~/Library/Keychains/login.keychain-db
Full log: $log"
        fi
        if grep -qE 'No Account for Team|No accounts? (with|for)|requires a provisioning profile|No profiles for' "$log"; then
            die "Xcode has no signing account/profile for team $APPLE_TEAM_ID. Open Xcode > Settings > Accounts,
sign in to your Apple ID, and make sure the team ID matches. Full log: $log"
        fi
        if grep -qE 'Failed Registering Bundle Identifier|identifier .* is not available' "$log"; then
            die "bundle id under '$APP_BUNDLE_ID_PREFIX' is taken by another team; choose another APP_BUNDLE_ID_PREFIX. Full log: $log"
        fi
        die "xcodebuild failed (exit $rc). Last lines of $log:
$(grep -E 'error' "$log" | tail -n 15)"
    fi

    local app
    app="$(find "$DERIVED_DIR/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' -newer "$pbx" | head -n1)"
    [[ -n "$app" ]] || app="$(find "$DERIVED_DIR/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' | head -n1)"
    [[ -n "$app" && -d "$app" ]] || die "build succeeded but no .app under $DERIVED_DIR/Build/Products/Release-iphoneos"
    printf '%s\n' "$app" > "$LAST_APP_FILE"
    ok "built $app"
    ok "bundle id $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
}

mac_pick_device() {
    if ! xcrun --find devicectl >/dev/null 2>&1; then
        die "devicectl not available; it ships with Xcode 15+. Is Xcode selected (xcode-select -p)?"
    fi
    local json="$BUILD_HOME/devices.json"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 \
        || die "'xcrun devicectl list devices' failed"
    # shellcheck disable=SC2016
    node -e '
const fs = require("fs");
const want = process.argv[2] || "";
const devs = (JSON.parse(fs.readFileSync(process.argv[1], "utf8")).result || {}).devices || [];
const phones = devs.filter(d => (d.hardwareProperties||{}).platform === "iOS" && (d.hardwareProperties||{}).reality === "physical");
const describe = d => `${d.deviceProperties.name} [${d.identifier}] pairing=${(d.connectionProperties||{}).pairingState} tunnel=${(d.connectionProperties||{}).tunnelState} transport=${(d.connectionProperties||{}).transportType||"-"} devmode=${d.deviceProperties.developerModeStatus||"?"}`;
phones.forEach(d => console.error("   device: " + describe(d)));
let pick = phones;
if (want) pick = phones.filter(d => [d.identifier, d.deviceProperties.name, (d.hardwareProperties||{}).udid].includes(want));
else pick = phones.filter(d => (d.connectionProperties||{}).pairingState === "paired");
const avail = pick.filter(d => (d.connectionProperties||{}).tunnelState !== "unavailable");
const chosen = avail[0] || pick[0];
if (!chosen) { process.exit(2); }
if (!want && avail.length > 1) console.error("   (several paired iPhones; using the first. Pass --device to choose.)");
if (chosen.deviceProperties.developerModeStatus && chosen.deviceProperties.developerModeStatus !== "enabled")
    console.error("   WARNING: Developer Mode is not enabled on " + chosen.deviceProperties.name);
process.stdout.write(chosen.identifier + "\t" + chosen.deviceProperties.name);
' "$json" "$DEVICE"
}

mac_stage_install() {
    step "Install on iPhone"
    mac_load_config
    [[ -f "$LAST_APP_FILE" ]] || die "nothing built yet. Run without --install-only (or with --build-only) first."
    local app picked dev_id dev_name bundle
    app="$(cat "$LAST_APP_FILE")"
    [[ -d "$app" ]] || die "last build $app is gone. Rebuild."
    set +e
    picked="$(mac_pick_device)"
    local rc=$?
    set -e
    if [[ $rc -ne 0 || -z "$picked" ]]; then
        # shellcheck disable=SC2016
        die "no paired iPhone found${DEVICE:+ matching '$DEVICE'}. First time: connect it by USB, unlock it,
tap 'Trust This Computer', enable Settings > Privacy & Security > Developer Mode, and open
Xcode > Window > Devices and Simulators once so it pairs. After that it also works over Wi-Fi
(same network, phone unlocked)."
    fi
    dev_id="${picked%%$'\t'*}"; dev_name="${picked#*$'\t'}"
    ok "device: $dev_name ($dev_id)"
    ok "app:    $app"
    xcrun devicectl device install app --device "$dev_id" "$app" \
        || die "install failed. Is the phone unlocked, Developer Mode on, and is it the device the profile was made for?
Free teams: at most 3 sideloaded apps per device."
    bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
    if ! xcrun devicectl device process launch --device "$dev_id" "$bundle" >/dev/null 2>&1; then
        warn "installed, but iOS refused to launch it. On the iPhone: Settings > General > VPN & Device Management >
       Apple Development: <your Apple ID> > Trust, then open the app."
    else
        ok "launched $bundle"
    fi
}

if [[ -n "$MAC_STAGE" ]]; then
    mac_env
    case "$MAC_STAGE" in
        deps)    mac_stage_deps ;;
        build)   mac_stage_build ;;
        install) mac_stage_install ;;
        *)       die "unknown --mac-stage '$MAC_STAGE'" ;;
    esac
    exit 0
fi

# ======================================================================
# Driver. On Linux: sync over ssh. On the Mac itself: run the stages locally.
# ======================================================================

resolve_server_url() {
    if [[ -n "${SELFHOST_SERVER_URL:-}" ]]; then printf '%s' "${SELFHOST_SERVER_URL%/}"; return; fi
    local envf v
    # Only the PUBLIC_URL line is read; nothing else from the secrets file.
    for envf in "$REPO_ROOT/selfhost/.env" "/home/prep/happy/selfhost/.env"; do
        if [[ -f "$envf" ]]; then
            v="$(sed -n 's/^PUBLIC_URL=["'\'']\{0,1\}\([^"'\'' ]*\).*/\1/p' "$envf" | tail -n1)"
            if [[ -n "$v" ]]; then printf '%s' "${v%/}"; return; fi
        fi
    done
    printf '%s' "https://happy.girthbass.duckdns.org"
}

# Values forwarded to the Mac stages (only the ones that are set).
forward_env() {
    local -a kv=()
    kv+=("HB_COMMIT_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)")
    kv+=("HB_COMMIT_TS=$(git -C "$REPO_ROOT" show -s --format=%cI HEAD 2>/dev/null || true)")
    kv+=("HB_SERVER_URL=$(resolve_server_url)")
    local team="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
    [[ -n "$team" ]] && kv+=("HB_APPLE_TEAM_ID=$team")
    [[ -n "${APP_BUNDLE_ID_PREFIX:-}" ]] && kv+=("HB_APP_BUNDLE_ID_PREFIX=$APP_BUNDLE_ID_PREFIX")
    [[ -n "${APP_DISPLAY_NAME:-}" ]] && kv+=("HB_APP_DISPLAY_NAME=$APP_DISPLAY_NAME")
    [[ -n "${APP_ENV:-}" ]] && kv+=("HB_APP_ENV=$APP_ENV")
    printf '%s\0' ${kv[@]+"${kv[@]}"}
}

STAGE_ARGS=()
[[ $SKIP_PREBUILD -eq 1 ]] && STAGE_ARGS+=(--skip-prebuild)
[[ -n "$DEVICE_ARG" ]] && STAGE_ARGS+=(--device "$DEVICE_ARG")

run_stage() {   # run_stage deps|build|install
    local stage="$1" cmd q item
    local -a envs=()
    while IFS= read -r -d '' item; do envs+=("$item"); done < <(forward_env)
    if [[ "$(uname -s)" == "Darwin" ]]; then
        env ${envs[@]+"${envs[@]}"} bash "$SCRIPT_DIR/build-on-mac.sh" --mac-stage "$stage" ${STAGE_ARGS[@]+"${STAGE_ARGS[@]}"}
        return
    fi
    cmd="env"
    for item in ${envs[@]+"${envs[@]}"}; do printf -v q '%q' "$item"; cmd+=" $q"; done
    cmd+=" MAC_HOST=$(printf '%q' "$MAC_HOST") REMOTE_DIR=$(printf '%q' "$REMOTE_DIR")"
    cmd+=" bash \"\$HOME\"/$(printf '%q' "$REMOTE_DIR/$SELF_REL") --mac-stage $stage"
    for item in ${STAGE_ARGS[@]+"${STAGE_ARGS[@]}"}; do printf -v q '%q' "$item"; cmd+=" $q"; done
    ssh -o BatchMode=yes "$MAC_HOST" "$cmd"
}

do_sync() {
    step "rsync $REPO_ROOT -> $MAC_HOST:~/$REMOTE_DIR"
    command -v rsync >/dev/null || die "rsync not installed"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$MAC_HOST" true \
        || die "cannot ssh to '$MAC_HOST' (key-based login required)"
    local backup="../happy-build-trash/${TS}_rsync_replaced"
    # Filter order matters: first match wins. Excluded paths on the Mac
    # (node_modules, ios/, .env.ios, ...) are never deleted by --delete.
    # macOS ships openrsync, which lacks some options; use Homebrew rsync there.
    ssh -o BatchMode=yes "$MAC_HOST" 'test -x /opt/homebrew/bin/rsync' \
        || die "Homebrew rsync missing on the Mac. Run there: brew install rsync"
    rsync -a --delete --rsync-path=/opt/homebrew/bin/rsync --backup --backup-dir="$backup" \
        --exclude='.git' \
        --exclude='node_modules/' \
        --exclude='.claude/' \
        --exclude='/trash/' \
        --exclude='/ios/' --exclude='/android/' \
        --exclude='/packages/happy-app/ios/' --exclude='/packages/happy-app/android/' \
        --exclude='.env*' --exclude='.envrc' \
        --exclude='*.pem' --exclude='*.key' --exclude='*.p8' --exclude='*.p12' \
        --exclude='*.jks' --exclude='*.mobileprovision' \
        --include='/selfhost/' --include='/selfhost/ios/' --include='/selfhost/ios/**' \
        --exclude='/selfhost/**' \
        --exclude='.expo/' --exclude='.DS_Store' \
        --exclude='/packages/happy-app/public/canvaskit.wasm' \
        --filter=':- .gitignore' \
        "$REPO_ROOT/" "$MAC_HOST:$REMOTE_DIR/"
    # rsync --backup keeps anything it deleted or replaced; label it if present.
    # shellcheck disable=SC2016
    ssh -o BatchMode=yes "$MAC_HOST" "d=\"\$HOME/happy-build-trash/${TS}_rsync_replaced\"; if [ -d \"\$d\" ]; then printf '# rsync backup\n\nFiles under ~/$REMOTE_DIR that %s deleted or replaced on %s (source no longer had them or they changed). Kept instead of deleted.\n' '$SELF_REL' '$TS' > \"\$d/NOTE.md\"; echo \"  note  replaced/deleted files kept in \$d\"; fi"
    ok "synced (commit $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')$(git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null || echo ', plus uncommitted changes'))"
}

if [[ "$(uname -s)" != "Darwin" && $DO_SYNC -eq 1 ]]; then
    do_sync
fi
if [[ $DO_SYNC -eq 1 && $SKIP_DEPS -eq 0 ]]; then run_stage deps; fi
if [[ $DO_BUILD -eq 1 ]]; then run_stage build; fi
if [[ $DO_INSTALL -eq 1 ]]; then run_stage install; fi

step "Done"
