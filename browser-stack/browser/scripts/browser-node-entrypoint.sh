#!/usr/bin/env bash
# browser-node entrypoint for host networking (mounted read-only, run as the
# container's entrypoint). It runs the image's own /entrypoint.sh, patched in
# five places, because with network_mode: host every listener is on this
# machine's interfaces, and because the screen must only ever show one page:
#
#   - websockify (noVNC) is started with a bare port, `6080`, which binds every
#     interface. It is rewritten to `127.0.0.1:$NOVNC_PORT`.
#   - Xvfb is given `-nolisten tcp -nolisten local`. `local` is the Linux
#     abstract socket @/tmp/.X11-unix/X99, which lives in the network namespace:
#     on the host's it would be a display any local process could open (Xvfb
#     runs with -ac) and could clash with a host X server on :99, or with
#     another browser pod's :99. The path socket /tmp/.X11-unix/X99 stays,
#     private to this container's /tmp.
#   - fluxbox runs with a read-only config from /happy/fluxbox: no toolbar,
#     one workspace, no key or mouse bindings, no menu, every window
#     undecorated and maximized. BROWSER_KIOSK=0 (the default) uses
#     init.window: a plain dark desktop behind a normal maximized Chromium
#     window with its tab strip and address bar. BROWSER_KIOSK=1 uses init:
#     every window fullscreen too.
#   - x11vnc gets -noremote -norc -nowf -nonap and a clip to the screen, so a
#     viewer cannot drive x11vnc itself or see past the screen.
#   - Chromium is launched through /opt/browser-node/happy-kiosk.mjs, which adds
#     its flags to server.mjs's launch and holds every window maximized (or,
#     with BROWSER_KIOSK=1, in --kiosk fullscreen).
#
# The Playwright server's bind comes from PLAYWRIGHT_SERVER_HOST and x11vnc is
# on a unix socket already, so neither needs a listener patch. If the upstream
# script changes so a pattern no longer matches, this refuses to start rather
# than run a listener on the LAN or an unlocked window.
set -euo pipefail

NOVNC_PORT="${NOVNC_PORT:-6080}"
[[ "$NOVNC_PORT" =~ ^[0-9]+$ ]] || { echo "browser-node-entrypoint: bad NOVNC_PORT" >&2; exit 1; }
[[ "${PLAYWRIGHT_SERVER_HOST:-}" == 127.0.0.1 ]] \
  || { echo "browser-node-entrypoint: PLAYWRIGHT_SERVER_HOST must be 127.0.0.1" >&2; exit 1; }
case "${BROWSER_KIOSK:-0}" in
  0) fluxbox_rc=/happy/fluxbox/init.window ;;
  1) fluxbox_rc=/happy/fluxbox/init ;;
  *) echo "browser-node-entrypoint: BROWSER_KIOSK must be 0 or 1" >&2; exit 1 ;;
esac
# BROWSER_NODE_ENTRYPOINT_DRY_RUN=1 (tests) only patches and checks; it skips this and the exec.
if [[ "${BROWSER_NODE_ENTRYPOINT_DRY_RUN:-}" != 1 ]]; then
  for f in /opt/browser-node/happy-kiosk.mjs /happy/fluxbox/init /happy/fluxbox/keys /happy/fluxbox/apps /happy/fluxbox/menu \
      /happy/fluxbox/init.window /happy/fluxbox/apps.window; do
    [[ -f "$f" ]] || { echo "browser-node-entrypoint: $f is missing; refusing to start" >&2; exit 1; }
  done
fi

src="${BROWSER_NODE_ENTRYPOINT_SRC:-/entrypoint.sh}"
out="${BROWSER_NODE_ENTRYPOINT_OUT:-/tmp/entrypoint.host-net.sh}"

ws_pattern='^  6080 >/tmp/novnc.log 2>&1 &$'
xvfb_pattern='^run_as_browser Xvfb "\$DISPLAY" -screen 0 '
wm_pattern='^run_as_browser fluxbox >/tmp/fluxbox.log 2>&1 &$'
vnc_pattern=' -xkb >/tmp/x11vnc.log '
node_pattern='run_as_browser node /opt/browser-node/server\.mjs '
for p in "$ws_pattern" "$xvfb_pattern" "$wm_pattern" "$vnc_pattern" "$node_pattern"; do
  n="$(grep -cE "$p" "$src" || true)"
  if [[ "$n" != 1 ]]; then
    echo "browser-node-entrypoint: $src no longer matches /$p/ exactly once ($n); refusing to start" >&2
    exit 1
  fi
done

# ${WIDTH}/${HEIGHT} stay literal here: the upstream script defines and expands them.
sed -E \
  -e "s|$ws_pattern|  127.0.0.1:${NOVNC_PORT} >/tmp/novnc.log 2>\&1 \&|" \
  -e "s|$xvfb_pattern|run_as_browser Xvfb \"\$DISPLAY\" -nolisten tcp -nolisten local -screen 0 |" \
  -e "s|$wm_pattern|run_as_browser fluxbox -rc ${fluxbox_rc} >/tmp/fluxbox.log 2>\&1 \&|" \
  -e "s|$vnc_pattern| -xkb -noremote -norc -nowf -nonap -clip \${WIDTH}x\${HEIGHT}+0+0 >/tmp/x11vnc.log |" \
  -e "s|$node_pattern|run_as_browser node /opt/browser-node/happy-kiosk.mjs |" \
  "$src" >"$out"
chmod 0755 "$out"

grep -qE "^  127\.0\.0\.1:${NOVNC_PORT} >/tmp/novnc.log" "$out" \
  && grep -qE '^run_as_browser Xvfb "\$DISPLAY" -nolisten tcp -nolisten local ' "$out" \
  && grep -qE "^run_as_browser fluxbox -rc ${fluxbox_rc//./\\.} >" "$out" \
  && grep -qE ' -xkb -noremote -norc -nowf -nonap -clip \$\{WIDTH\}x\$\{HEIGHT\}\+0\+0 >/tmp/x11vnc.log' "$out" \
  && grep -qE 'run_as_browser node /opt/browser-node/happy-kiosk\.mjs ' "$out" \
  && ! grep -qE 'node /opt/browser-node/server\.mjs' "$out" \
  || { echo "browser-node-entrypoint: patch did not apply; refusing to start" >&2; exit 1; }

[[ "${BROWSER_NODE_ENTRYPOINT_DRY_RUN:-}" == 1 ]] && exit 0
exec "$out" "$@"
