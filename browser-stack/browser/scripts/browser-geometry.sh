#!/bin/sh
# The browser's geometry, worked out one way for browser.mk and for selfhost/svc/happy-svc-ctl:
#
#   BROWSER_KIOSK=0|1 BROWSER_HEIGHT=<px> BROWSER_WIDTH=<px> sh browser-geometry.sh <fluxbox init.window>
#
# Prints KEY=value lines (BROWSER_KIOSK, BROWSER_WIDTH, BROWSER_HEIGHT, CHROME_UI_HEIGHT,
# BROWSER_PANEL_HEIGHT, BROWSER_VIEWPORT_HEIGHT), or a reason on stderr and exits 1 if any input
# or result is not an integer in range. Unset or empty inputs take the compose defaults (0, 1200,
# 1920). The page's height: the whole screen in kiosk mode; otherwise the screen less the desktop
# panel (the toolbar.height of kiosk/fluxbox/init.window, when its toolbar is visible) and
# Chromium's tab strip and toolbar (CHROME_UI_HEIGHT, measured on the pinned image; the launcher's
# launcher.mjs has the same constant). POSIX sh, no environment beyond the three inputs.
set -eu

CHROME_UI_HEIGHT=87

die() { printf 'browser-geometry: %s\n' "$*" >&2; exit 1; }

# A decimal integer without leading zeros (sh arithmetic would read 0123 as octal), in [lo, hi].
int_in() {   # name, value, lo, hi
    case $2 in ''|*[!0-9]*|0?*) die "$1 is not a decimal integer (got '$2')" ;; esac
    [ ${#2} -le 6 ] || die "$1 is out of range"
    if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then die "$1 must be $3..$4 (got $2)"; fi
}

[ $# -eq 1 ] || die "usage: BROWSER_KIOSK=.. BROWSER_HEIGHT=.. BROWSER_WIDTH=.. browser-geometry.sh <init.window>"
init=$1
[ -f "$init" ] || die "$init: no such file"

kiosk=${BROWSER_KIOSK:-0}
height=${BROWSER_HEIGHT:-1200}
width=${BROWSER_WIDTH:-1920}
case $kiosk in 0|1) ;; *) die "BROWSER_KIOSK must be 0 or 1 (got '$kiosk')" ;; esac
int_in BROWSER_HEIGHT "$height" 240 4320
int_in BROWSER_WIDTH "$width" 320 7680

panel=0
if [ "$kiosk" = 0 ] && grep -qE '^session\.screen0\.toolbar\.visible:[[:space:]]*true[[:space:]]*$' "$init"; then
    panel=$(sed -nE 's/^session\.screen0\.toolbar\.height:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$init" | tail -n 1)
    panel=${panel:-0}
fi
int_in BROWSER_PANEL_HEIGHT "$panel" 0 200

if [ "$kiosk" = 1 ]; then viewport=$height; else viewport=$((height - panel - CHROME_UI_HEIGHT)); fi
int_in BROWSER_VIEWPORT_HEIGHT "$viewport" 100 4320

printf 'BROWSER_KIOSK=%s\nBROWSER_WIDTH=%s\nBROWSER_HEIGHT=%s\nCHROME_UI_HEIGHT=%s\nBROWSER_PANEL_HEIGHT=%s\nBROWSER_VIEWPORT_HEIGHT=%s\n' \
    "$kiosk" "$width" "$height" "$CHROME_UI_HEIGHT" "$panel" "$viewport"
