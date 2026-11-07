#!/bin/bash
# Stop the com.happy.browser-forward launchd agent and move its plist to
# ~/happy-trash/<ts>_browser-forward/ (never deleted). Run it on the Mac.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL=com.happy.browser-forward
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null; then echo "stopped $LABEL"; else echo "$LABEL was not loaded"; fi
if [ -f "$PLIST" ]; then
  trash="$HOME/happy-trash/$(date +%Y%m%d_%H%M%S)_browser-forward"
  mkdir -p "$trash"
  mv "$PLIST" "$trash/"
  echo "plist moved out of ~/Library/LaunchAgents by uninstall.sh" >"$trash/NOTE.md"
  echo "plist moved to $trash"
else
  echo "no $PLIST"
fi
