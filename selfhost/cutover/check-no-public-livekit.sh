#!/usr/bin/env bash
# Verifies that no public path reaches LiveKit and that the internal paths still do.
# Read-only (HTTP requests and `docker exec ... curl`). Exit 0 when every check passes.
#
#   bash selfhost/cutover/check-no-public-livekit.sh [--lan 192.168.2.72]
#
# LiveKit fingerprints: GET / answers "OK"; /rtc/validate answers "no permissions to access the room".
set -uo pipefail
LAN_IP=192.168.2.72
[ "${1:-}" = "--lan" ] && LAN_IP=$2
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

echo "== host ports (LAN address must not expose 7880/7881; nothing listens on 7882 outside docker)"
for p in 7880 7881; do
    if timeout 3 bash -c "</dev/tcp/$LAN_IP/$p" 2>/dev/null; then fail "tcp $LAN_IP:$p accepts connections"
    else pass "tcp $LAN_IP:$p closed"; fi
done
if ss -H -lun 2>/dev/null | awk '{print $4}' | grep -qE ':7882$'; then fail "a host socket listens on udp 7882: $(ss -H -lun | grep ':7882' | awk '{print $4}' | tr '\n' ' ')"
else pass "no host udp 7882 listener"; fi
if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE ':7881$'; then fail "a host socket listens on tcp 7881"
else pass "no host tcp 7881 listener"; fi

echo "== internal paths (must reach LiveKit)"
out=$(curl -fsS -m 3 http://127.0.0.1:7880/ 2>&1); [ "$out" = OK ] && pass "agent path 127.0.0.1:7880 -> OK" || fail "127.0.0.1:7880: $out"
out=$(docker exec happy-selfhost-happy-server-1 curl -fsS -m 3 http://livekit:7880/ 2>&1); [ "$out" = OK ] && pass "happy-server -> ws://livekit:7880 OK" || fail "happy-server -> livekit:7880: $out"
ip=$(docker inspect happy-voice-livekit --format '{{with index .NetworkSettings.Networks "happy-selfhost_default"}}{{.IPAddress}}{{end}}' 2>/dev/null)
if [ -n "$ip" ]; then
    pass "livekit container on happy-selfhost_default at $ip"
    timeout 3 bash -c "</dev/tcp/$ip/7881" 2>/dev/null && pass "host -> $ip:7881 (ICE/TCP) reachable" || fail "host -> $ip:7881 unreachable"
    docker logs happy-voice-livekit 2>&1 | grep -q "\"nodeIP\": \"$ip\"" && pass "LiveKit nodeIP is $ip" || fail "LiveKit log does not show nodeIP $ip"
else
    fail "livekit container not on happy-selfhost_default"
fi

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit $((fails > 0))
