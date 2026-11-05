#!/bin/bash
# Install (or reinstall) the com.happy.browser-forward launchd user agent on this Mac.
# It keeps an ssh tunnel up from 127.0.0.1:6090 and 127.0.0.1:6080 here to the browser
# bridge and noVNC on prep-ml, so the app's live view (http://localhost:6090/live/...) and
# takeover work for chats that run on this Mac. Run it on the Mac, from this folder:
#
#   ./install.sh                     install, then check /healthz through the tunnel
#   REMOTE=other-host ./install.sh   tunnel to another host (default prep-ml)
#
# Refuses if anything other than this agent already listens on 6090 or 6080.
# A previous plist that differs is copied to ~/happy-trash/<ts>_browser-forward/ first.
# Remove with ./uninstall.sh.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=com.happy.browser-forward
REMOTE=${REMOTE:-prep-ml}
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
DOMAIN="gui/$(id -u)"

[ "$(uname -s)" = Darwin ] || { echo "run this on the Mac"; exit 1; }
[[ "$REMOTE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad REMOTE: $REMOTE"; exit 1; }

# pids listening on :6090 or :6080 (empty when none)
listeners() {
  lsof -nP -t -iTCP:6090 -iTCP:6080 -sTCP:LISTEN 2>/dev/null | sort -u || true
}

agent_pid() {
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '$1 == "pid" && $2 == "=" {print $3; exit}' || true
}

# Anything other than our own tunnel on the ports: stop.
ours=$(agent_pid)
for pid in $(listeners); do
  if [ -z "$ours" ] || [ "$pid" != "$ours" ]; then
    echo "refusing: pid $pid already listens on 6090 or 6080:"
    lsof -nP -iTCP:6090 -iTCP:6080 -sTCP:LISTEN || true
    exit 1
  fi
done

echo "== checking ssh to $REMOTE"
/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "$REMOTE" true \
  || { echo "ssh -o BatchMode=yes $REMOTE failed; set up the key first"; exit 1; }

mkdir -p "$AGENTS" "$HOME/Library/Logs"
new=$(mktemp)
trap 'rm -f "$new"' EXIT
sed -e "s|__HOME__|$HOME|g" -e "s|__REMOTE__|$REMOTE|g" "$HERE/$LABEL.plist" >"$new"
plutil -lint "$new" >/dev/null

if [ -f "$PLIST" ] && ! cmp -s "$new" "$PLIST"; then
  trash="$HOME/happy-trash/$(date +%Y%m%d_%H%M%S)_browser-forward"
  mkdir -p "$trash"
  cp -p "$PLIST" "$trash/"
  echo "previous $PLIST, replaced by install.sh" >"$trash/NOTE.md"
  echo "== previous plist backed up to $trash"
fi

echo "== loading $LABEL"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before the old tunnel has let go of the ports.
for _ in $(seq 1 20); do [ -z "$(listeners)" ] && break; sleep 0.5; done
cp "$new" "$PLIST"
chmod 644 "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "== waiting for the tunnel"
for _ in $(seq 1 30); do
  if out=$(curl -fsS --max-time 3 http://127.0.0.1:6090/healthz 2>/dev/null); then
    echo "bridge /healthz through the tunnel: $out"
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:6080/ || true)
    echo "noVNC :6080 through the tunnel: HTTP $code"
    exit 0
  fi
  sleep 1
done
echo "the tunnel did not answer within 30s; see $HOME/Library/Logs/happy-browser-forward.log"
launchctl print "$DOMAIN/$LABEL" | grep -E 'state|pid|last exit' || true
exit 1
