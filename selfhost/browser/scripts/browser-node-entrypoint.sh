#!/usr/bin/env bash
# browser-node entrypoint for host networking (mounted read-only, run as the
# container's entrypoint). It runs the image's own /entrypoint.sh, patched in
# two places, because with network_mode: host every listener is on this
# machine's interfaces:
#
#   - websockify (noVNC) is started with a bare port, `6080`, which binds every
#     interface. It is rewritten to `127.0.0.1:$NOVNC_PORT`.
#   - Xvfb is given `-nolisten tcp -nolisten local`. `local` is the Linux
#     abstract socket @/tmp/.X11-unix/X99, which lives in the network namespace:
#     on the host's it would be a display any local process could open (Xvfb
#     runs with -ac) and could clash with a host X server on :99. The path
#     socket /tmp/.X11-unix/X99 stays, private to this container's /tmp.
#
# The Playwright server's bind comes from PLAYWRIGHT_SERVER_HOST and x11vnc is
# on a unix socket already, so neither needs a patch. If the upstream script
# changes so a pattern no longer matches, this refuses to start rather than run
# a listener on the LAN.
set -euo pipefail

NOVNC_PORT="${NOVNC_PORT:-6080}"
[[ "$NOVNC_PORT" =~ ^[0-9]+$ ]] || { echo "browser-node-entrypoint: bad NOVNC_PORT" >&2; exit 1; }
[[ "${PLAYWRIGHT_SERVER_HOST:-}" == 127.0.0.1 ]] \
  || { echo "browser-node-entrypoint: PLAYWRIGHT_SERVER_HOST must be 127.0.0.1" >&2; exit 1; }

src=/entrypoint.sh
out=/tmp/entrypoint.host-net.sh

ws_pattern='^  6080 >/tmp/novnc.log 2>&1 &$'
xvfb_pattern='^run_as_browser Xvfb "\$DISPLAY" -screen 0 '
for p in "$ws_pattern" "$xvfb_pattern"; do
  n="$(grep -cE "$p" "$src" || true)"
  if [[ "$n" != 1 ]]; then
    echo "browser-node-entrypoint: $src no longer matches /$p/ exactly once ($n); refusing to start" >&2
    exit 1
  fi
done

sed -E \
  -e "s|$ws_pattern|  127.0.0.1:${NOVNC_PORT} >/tmp/novnc.log 2>\&1 \&|" \
  -e "s|$xvfb_pattern|run_as_browser Xvfb \"\$DISPLAY\" -nolisten tcp -nolisten local -screen 0 |" \
  "$src" >"$out"
chmod 0755 "$out"

grep -qE "^  127\.0\.0\.1:${NOVNC_PORT} >/tmp/novnc.log" "$out" \
  && grep -qE '^run_as_browser Xvfb "\$DISPLAY" -nolisten tcp -nolisten local ' "$out" \
  || { echo "browser-node-entrypoint: patch did not apply; refusing to start" >&2; exit 1; }

exec "$out" "$@"
