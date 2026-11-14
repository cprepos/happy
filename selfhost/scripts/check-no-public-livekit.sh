#!/usr/bin/env bash
# Verifies that no public path reaches LiveKit and that the internal paths still do.
# Read-only (HTTP requests, `docker exec` and one ssh log read). Exit 0 when every check passes.
#
#   bash selfhost/scripts/check-no-public-livekit.sh [--lan 192.168.2.72]
#   MAC_IP=192.168.2.56 MAC_SSH=prep-air SERVER_CTR=happy-selfhost-happy-server-rs-1 (defaults)
#
# LiveKit fingerprints: GET / answers "OK"; /rtc/validate answers "no permissions to access the room".
set -uo pipefail
LAN_IP=192.168.2.72
[ "${1:-}" = "--lan" ] && LAN_IP=$2
MAC_IP=${MAC_IP:-192.168.2.56}          # prep-air, where LiveKit runs
MAC_SSH=${MAC_SSH:-prep-air}            # empty skips the ssh log check
SERVER_CTR=${SERVER_CTR:-happy-selfhost-happy-server-rs-1}
fails=0
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; fails=$((fails + 1)); }

is_livekit() { grep -qE '^OK$|no permissions to access the room' <<<"$1"; }

# $1 label, $2 url, rest: extra curl args. Passes when the answer is not LiveKit's.
public_check() {
    local label=$1 url=$2; shift 2
    local out code
    out=$(curl -sS -m 8 -w '\n%{http_code}' "$@" "$url" 2>&1)
    code=${out##*$'\n'}
    out=${out%$'\n'*}
    if is_livekit "$out" || [ "$code" = 101 ]; then
        fail "$label: LiveKit answered ($code) at $url"
    else
        pass "$label: no LiveKit at $url (${code:-no answer}: $(head -c 60 <<<"$out" | tr '\n' ' '))"
    fi
}
WS=(-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' --http1.1)

echo "== public paths (must NOT reach LiveKit)"
public_check "livekit site /"            https://livekit.girthbass.duckdns.org/
public_check "livekit site /rtc/validate" https://livekit.girthbass.duckdns.org/rtc/validate
public_check "livekit site ws"           https://livekit.girthbass.duckdns.org/rtc "${WS[@]}"
public_check "/livekit page"             https://girthbass.duckdns.org/livekit/
public_check "/livekit ws /"             https://girthbass.duckdns.org/livekit/ "${WS[@]}"
public_check "/livekit ws /rtc/validate" https://girthbass.duckdns.org/livekit/rtc/validate "${WS[@]}"
public_check "happy site /rtc/validate"  https://happy.girthbass.duckdns.org/rtc/validate

echo "== prep-ml host ports (LAN address must not expose 7880/7881; nothing listens on 7882 outside docker)"
for p in 7880 7881; do
    if timeout 3 bash -c "</dev/tcp/$LAN_IP/$p" 2>/dev/null; then fail "tcp $LAN_IP:$p accepts connections"
    else pass "tcp $LAN_IP:$p closed"; fi
done
if ss -H -lun 2>/dev/null | awk '{print $4}' | grep -qE ':7882$'; then fail "a host socket listens on udp 7882: $(ss -H -lun | grep ':7882' | awk '{print $4}' | tr '\n' ' ')"
else pass "no host udp 7882 listener"; fi
if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE ':7881$'; then fail "a host socket listens on tcp 7881"
else pass "no host tcp 7881 listener"; fi

echo "== internal paths (must reach prep-air's LiveKit, $MAC_IP)"
# LiveKit runs natively on prep-air (selfhost/mac-voice/livekit.yaml, launchd com.openclaw.livekit).
out=$(curl -fsS -m 3 "http://$MAC_IP:7880/" 2>&1); [ "$out" = OK ] && pass "prep-ml -> $MAC_IP:7880 OK" || fail "prep-ml -> $MAC_IP:7880: $out"
# The Rust server image has no curl; bash's /dev/tcp is enough for a GET.
out=$(docker exec "$SERVER_CTR" bash -c "exec 3<>/dev/tcp/$MAC_IP/7880; printf 'GET / HTTP/1.0\\r\\n\\r\\n' >&3; tail -n1 <&3" 2>&1)
[ "$out" = OK ] && pass "$SERVER_CTR -> ws://$MAC_IP:7880 OK" || fail "$SERVER_CTR -> $MAC_IP:7880: $out"
timeout 3 bash -c "</dev/tcp/$MAC_IP/7881" 2>/dev/null && pass "prep-ml -> $MAC_IP:7881 (ICE/TCP) reachable" || fail "prep-ml -> $MAC_IP:7881 unreachable"
if [ -n "$MAC_SSH" ]; then
    # operator check over ssh: the live log names the advertised node IP
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$MAC_SSH" "grep 'starting LiveKit server' /tmp/openclaw-livekit.err | tail -n1" 2>/dev/null \
        | grep "\"nodeIP\": \"$MAC_IP\"" >/dev/null && pass "LiveKit nodeIP is $MAC_IP" || fail "LiveKit log does not show nodeIP $MAC_IP"
fi

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit $((fails > 0))
