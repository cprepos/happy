#!/usr/bin/env bash
# Build the Happy web app for the self-hosted server.
#
# Runs `expo export -p web` in packages/happy-app with the server URL baked in
# and analytics disabled, then places the result in selfhost/webapp/ (served by
# happy-server through HAPPY_STATIC_DIR).
#
# Env:
#   HAPPY_PUBLIC_URL   public origin of the server (default https://happy.girthbass.duckdns.org)
#   WEBAPP_OUT_DIR     output directory (default <repo>/selfhost/webapp)
#   SKIP_INSTALL=1     skip `pnpm install --frozen-lockfile`
#
# A previous build in WEBAPP_OUT_DIR is moved to
# <repo>/trash/<timestamp>_webapp_previous_build/ rather than deleted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$REPO_ROOT/packages/happy-app"

PUBLIC_URL="${HAPPY_PUBLIC_URL:-https://happy.girthbass.duckdns.org}"
PUBLIC_URL="${PUBLIC_URL%/}"
OUT_DIR="${WEBAPP_OUT_DIR:-$REPO_ROOT/selfhost/webapp}"
STAGE_DIR="$REPO_ROOT/selfhost/.webapp-build"
TRASH_DIR="$REPO_ROOT/trash"

case "$PUBLIC_URL" in
    http://*|https://*) ;;
    *) echo "HAPPY_PUBLIC_URL must start with http:// or https:// (got: $PUBLIC_URL)" >&2; exit 1 ;;
esac

cd "$REPO_ROOT"

if [ "${SKIP_INSTALL:-0}" != "1" ]; then
    echo "→ pnpm install --frozen-lockfile"
    pnpm install --frozen-lockfile
fi

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
COMMIT_TS="$(git -C "$REPO_ROOT" log -1 --format=%cI 2>/dev/null || echo unknown)"

# A leftover staging dir means an earlier run was interrupted; keep it in trash.
if [ -e "$STAGE_DIR" ]; then
    mkdir -p "$TRASH_DIR"
    mv "$STAGE_DIR" "$TRASH_DIR/$(date +%Y%m%d_%H%M%S)_webapp_stale_staging"
fi
mkdir -p "$(dirname "$STAGE_DIR")"

echo "→ Exporting web app (server: $PUBLIC_URL, analytics disabled)"
START=$(date +%s)
(
    cd "$APP_DIR"
    # Unset cloud keys so nothing from the caller's shell leaks into the bundle.
    env -u EXPO_PUBLIC_POSTHOG_API_KEY -u EXPO_PUBLIC_POSTHOG_KEY \
        -u EXPO_PUBLIC_REVENUE_CAT_STRIPE -u EXPO_PUBLIC_REVENUE_CAT_APPLE -u EXPO_PUBLIC_REVENUE_CAT_GOOGLE \
        NODE_ENV=production \
        APP_ENV=production \
        EXPO_PUBLIC_HAPPY_SERVER_URL="$PUBLIC_URL" \
        EXPO_PUBLIC_SERVER_URL="$PUBLIC_URL" \
        EXPO_PUBLIC_DISABLE_ANALYTICS=1 \
        HAPPY_BUILD_COMMIT_SHA="$COMMIT_SHA" \
        HAPPY_BUILD_COMMIT_TIMESTAMP="$COMMIT_TS" \
        pnpm exec expo export --platform web --output-dir "$STAGE_DIR" --clear
)
END=$(date +%s)

if [ ! -f "$STAGE_DIR/index.html" ]; then
    echo "expo export finished but $STAGE_DIR/index.html is missing" >&2
    exit 1
fi
if ! grep -rqF "$PUBLIC_URL" "$STAGE_DIR/_expo"; then
    echo "Server URL $PUBLIC_URL not found in the exported JS bundle" >&2
    exit 1
fi

cat > "$STAGE_DIR/build-info.json" <<JSON
{
  "serverUrl": "$PUBLIC_URL",
  "commit": "$COMMIT_SHA",
  "commitTimestamp": "$COMMIT_TS",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "analyticsDisabled": true
}
JSON

if [ -e "$OUT_DIR" ]; then
    mkdir -p "$TRASH_DIR"
    BACKUP="$TRASH_DIR/$(date +%Y%m%d_%H%M%S)_webapp_previous_build"
    mv "$OUT_DIR" "$BACKUP"
    echo "Previous selfhost web app build, replaced by build-webapp.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)." > "$BACKUP/TRASH_NOTE.txt"
    echo "→ Previous build moved to $BACKUP"
fi
mkdir -p "$(dirname "$OUT_DIR")"
mv "$STAGE_DIR" "$OUT_DIR"

echo "✓ webapp written to $OUT_DIR in $((END - START))s ($(du -sh "$OUT_DIR" | cut -f1))"
