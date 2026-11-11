#!/usr/bin/env bash
# Tests for selfhost/svc, runnable without root and without Docker (make svc-test):
#   1 shellcheck of every script
#   2 the sudoers drop-in through visudo -cf, raw and rendered
#   3 happy-svc-ctl in its test mode against a fake docker, curl and logger: refusals,
#     argument validation, the commands each verb runs, the cleared environment, the log
#   4 the root scripts refuse to run without root and refuse a malformed sha
# The work tree goes under ${TMPDIR:-/tmp} and is left there (nothing is deleted).
# SC2015: "A && ok || bad" is the intended report: bad on any failure.
# SC2016: the literal $(id) below is a value under test, never expanded.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

SVC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO=$(cd "$SVC/../.." && pwd)
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

echo "== 1 shellcheck"
if command -v shellcheck >/dev/null; then
    check "bash scripts" shellcheck "$SVC/setup-root.sh" "$SVC/teardown-root.sh" "$SVC/deploy-root.sh" "$SVC/test/run.sh"
    check "happy-svc-ctl (POSIX sh)" shellcheck -s sh "$SVC/happy-svc-ctl"
else
    bad "shellcheck is not installed"
fi

echo "== 2 sudoers"
VISUDO=$(command -v visudo || echo /usr/sbin/visudo)
T=$(mktemp -d "${TMPDIR:-/tmp}/happy-svc-test.XXXXXX")
sed "s/@OPERATOR@/prep/g" "$SVC/sudoers.happy-svc" >"$T/sudoers.rendered"
check "visudo -cf template" "$VISUDO" -cf "$SVC/sudoers.happy-svc"
check "visudo -cf rendered" "$VISUDO" -cf "$T/sudoers.rendered"
check "no password-free admin-tty or import" bash -c "! grep -Eq 'happy-svc-ctl (admin-tty|import)' '$T/sudoers.rendered'"
check "runas happy-svc only, never root" bash -c "grep -Eq '^prep ALL=\(happy-svc\) NOPASSWD: HAPPY_SVC_CTL$' '$T/sudoers.rendered' && ! grep -Eq '\(root|\(ALL' '$T/sudoers.rendered'"

echo "== 3 happy-svc-ctl (test mode, fake docker in $T)"
mkdir -p "$T/bin" "$T/opt" "$T/etc" "$T/drop/in" "$T/home" "$T/run/dockerd-rootless" "$T/log"
ln -s "$REPO" "$T/opt/current"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/run/dockerd-rootless/api.sock"
echo '[]' >"$T/log/rk-ports"
# The fakes find the log through their own path: happy-svc-ctl clears the environment.
cat >"$T/bin/docker" <<'EOF'
#!/bin/sh
D=$(cd "$(dirname "$0")/../log" && pwd)
printf '%s\n' "$*" >>"$D/docker.calls"
env >"$D/docker.env"
case " $* " in
    *" config --services "*) case " $* " in *" happy-vault "*) printf 'vaultwarden\nfiller\nfiller-admin\n' ;; *) printf 'bridge\ncontroller\n' ;; esac ;;
    " volume inspect "*) [ -e "$D/vol.$3" ] ;;
    " image inspect "*) [ -f "$D/image.id" ] && cat "$D/image.id" ;;
    " run "*) [ ! -f "$D/run.out" ] || cat "$D/run.out" ;;
esac
EOF
cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
D=$(cd "$(dirname "$0")/../log" && pwd)
printf '%s\n' "$*" >>"$D/curl.calls"
case " $* " in *" -X "*) echo '{}' ;; *) cat "$D/rk-ports" ;; esac
EOF
cat >"$T/bin/logger" <<'EOF'
#!/bin/sh
D=$(cd "$(dirname "$0")/../log" && pwd)
printf '%s\n' "$*" >>"$D/logger.calls"
EOF
chmod +x "$T/bin/docker" "$T/bin/curl" "$T/bin/logger"

CTL="$SVC/happy-svc-ctl"
ctl() { env -u SUDO_UID -u SUDO_USER HAPPY_SVC_CTL_TEST=1 HAPPY_SVC_CTL_TEST_ROOT="$T" SECRET_PROBE=leak "$CTL" "$@" </dev/null >"$T/log/out" 2>&1; }
runs() { : >"$T/log/docker.calls"; ctl "$@"; }
# Refused: a non-zero exit, and no docker command beyond reading the service list.
refused() { local n=$1; shift; : >"$T/log/docker.calls"
    if ctl "$@"; then bad "$n (ran)"; elif ! no_compose_action; then bad "$n (ran docker)"; else ok "$n"; fi; }
# Refused after a read-only docker step (a helper read, a volume inspect): a non-zero exit.
refused_late() { local n=$1; shift; : >"$T/log/docker.calls"; if ctl "$@"; then bad "$n (ran)"; else ok "$n"; fi; }
called() { grep -qF -- "$1" "$T/log/docker.calls"; }
no_compose_action() { ! grep -Ev ' config --services$' "$T/log/docker.calls" | grep -q .; }

check "refused without HAPPY_SVC_CTL_TEST" bash -c "! env -u HAPPY_SVC_CTL_TEST '$CTL' status >/dev/null 2>&1"
check "test mode refused under sudo" bash -c "! env SUDO_USER=prep HAPPY_SVC_CTL_TEST=1 HAPPY_SVC_CTL_TEST_ROOT='$T' '$CTL' status >/dev/null 2>&1"
check "test mode refused without a test root" bash -c "! env -u HAPPY_SVC_CTL_TEST_ROOT HAPPY_SVC_CTL_TEST=1 '$CTL' status >/dev/null 2>&1"

refused "no verb"
refused "unknown verb" sh
refused "verb with a newline" $'status\nup'
refused "up: unknown project" up happy
refused "up: two arguments" up vault browser
refused "down: unknown project" down 'vault;id'
refused "restart: no project" restart
refused "restart: service with a newline" restart vault $'filler\nx'
refused "restart: service not in the project" restart vault controller
refused "restart: service with a slash" restart vault ../filler
refused "logs: no service" logs vault
refused "logs: bad third argument" logs vault filler -f
refused "logs: four arguments" logs vault filler follow x
refused "status: an argument" status x
refused "ports: an argument" ports 1
refused "admin: unknown subcommand" admin enroll
refused "admin: policy-edit is admin-tty only" admin policy-edit
refused "admin token-issue: other name" admin token-issue NAME=root
refused "admin token-issue: bad second argument" admin token-issue NAME=vault-client ROTATE=yes
refused "admin seed-policy: bad client" admin seed-policy CLIENT=a/b
refused "admin seed-policy: not CLIENT=" admin seed-policy NAME=a
refused "admin items: extra argument" admin items x
refused "admin-tty: no terminal" admin-tty enroll
refused "admin-tty: other command" admin-tty items
refused "import: not in volumes.list" import happy-other
refused "import: path" import ../etc
refused "import: no tarball" import happy-vault-data
refused "tokens-export: an argument" tokens-export x

runs up vault && called "compose -p happy-vault" && called "up -d --build --wait" \
    && ! called "happy-browser" && ok "up vault: compose up of happy-vault only" || bad "up vault"
check "up vault: compose files from the release" grep -qF -- "-f $T/opt/current/selfhost/vault/compose.vault.yml -f $T/opt/current/selfhost/svc/compose.rootless.vault.yml" "$T/log/docker.calls"
n=$(grep -c 'X POST' "$T/log/curl.calls")
check "up: every ports.list port published (69)" test "$n" = 69
check "ports: only on 127.0.0.1" bash -c "! grep 'X POST' '$T/log/curl.calls' | grep -v '\"parentIP\":\"127.0.0.1\"' | grep -q ."
check "environment cleared (no SECRET_PROBE)" bash -c "! grep -q SECRET_PROBE '$T/log/docker.env'"
check "environment: DOCKER_HOST is happy-svc's socket" grep -qx "DOCKER_HOST=unix://$T/run/docker.sock" "$T/log/docker.env"
check "environment: LAN listener off" grep -qx "BRIDGE_LAN_BIND=" "$T/log/docker.env"
check "environment: docker-proxy upstream is happy-svc's socket" grep -qx "HAPPY_DOCKER_SOCKET=$T/run/docker.sock" "$T/log/docker.env"
check "environment: socket group 0 under rootless" grep -qx "DOCKER_SOCKET_GID=0" "$T/log/docker.env"
check "environment: service uids left to the compose defaults" bash -c "! grep -Eq '^(BRIDGE|CONTROLLER|BROWSER_NODE|DOCKER_PROXY)_[UG]ID=' '$T/log/docker.env'"

runs up && grep -n 'up -d' "$T/log/docker.calls" | head -1 | grep -q happy-vault && grep 'up -d' "$T/log/docker.calls" | tail -1 | grep -q happy-browser \
    && ok "up: vault, then browser" || bad "up: order"
runs down && grep ' down' "$T/log/docker.calls" | head -1 | grep -q happy-browser && ok "down: browser first" || bad "down: order"
runs logs vault filler follow && called "logs --no-color --tail 200 -f filler" && ok "logs follow" || bad "logs follow"
runs restart browser bridge && called "-p happy-browser" && called "restart bridge" && ok "restart browser bridge" || bad "restart"
runs admin token-issue NAME=bridge-client ROTATE=1 && called "run --rm --no-deps -T filler-admin token-issue NAME=bridge-client ROTATE=1" \
    && ok "admin token-issue" || bad "admin token-issue"

: >"$T/log/curl.calls"
echo '[{"id":7,"spec":{"proto":"tcp","parentIP":"0.0.0.0","parentPort":8222,"childIP":"127.0.0.1","childPort":8222}},
      {"id":8,"spec":{"proto":"tcp","parentIP":"127.0.0.1","parentPort":6091,"childIP":"127.0.0.1","childPort":6091}}]' >"$T/log/rk-ports"
runs ports
check "ports: a non-loopback port is removed" grep -q 'X DELETE http://rootlesskit/v1/ports/7' "$T/log/curl.calls"
check "ports: a loopback port is kept" bash -c "! grep -q 'ports/8' '$T/log/curl.calls'"
check "ports: an existing one is not added again (68)" test "$(grep -c 'X POST' "$T/log/curl.calls")" = 68
echo '[]' >"$T/log/rk-ports"

tok=$(printf 'a%.0s' $(seq 1 40))
idok="sha256:$(printf 'ab%.0s' $(seq 1 32))"
printf 'bridge-client-token %s\napi-token %s\n' "$tok" "$tok" >"$T/log/run.out"
runs tokens-export && grep -qx "bridge-client-token $tok" "$T/log/out" && ok "tokens-export: valid tokens printed" || bad "tokens-export"
printf 'api-token a$(id)aaaaaaaaaaaaaaaa\n' >"$T/log/run.out"
refused_late "tokens-export: a value that is not a token" tokens-export
printf 'api-token short\n' >"$T/log/run.out"
refused_late "tokens-export: too short" tokens-export
printf 'other-token %s\n' "$tok" >"$T/log/run.out"
refused_late "tokens-export: an unexpected name" tokens-export
mv "$T/log/run.out" "$T/log/run.out.done"

: >"$T/drop/in/happy-filler.tar"
touch "$T/log/vol.happy-filler"
refused_late "import: an existing volume is not overwritten" import happy-filler
check "import: the tarball stays in the drop" test -f "$T/drop/in/happy-filler.tar"
check "import: no volume created over it" bash -c "! grep -q 'volume create' '$T/log/docker.calls'"
: >"$T/drop/in/happy-vault-data.tar"
runs import happy-vault-data && called "volume create --label happy-svc.imported=1 happy-vault-data" \
    && test ! -e "$T/drop/in/happy-vault-data.tar" && ls "$T"/home/imported/*/happy-vault-data.tar >/dev/null 2>&1 \
    && ok "import: new volume, tarball moved to imported/" || bad "import"

# BROWSER_NODE_CHROME=1: up builds the release's node-chrome/Dockerfile in this daemon and runs
# it by its image id; nothing else may name the node image.
ctag="happy-browser-node-chrome:$(sed -nE 's/^ARG CHROME_VERSION=([0-9.]+)-[0-9]+$/\1/p' "$REPO/browser-stack/browser/node-chrome/Dockerfile")-$(sed -nE 's/^ARG IMAGE_REVISION=([0-9]+)$/\1/p' "$REPO/browser-stack/browser/node-chrome/Dockerfile")"
check "node-chrome: tag read from the Dockerfile ($ctag)" bash -c "[[ '$ctag' =~ ^happy-browser-node-chrome:[0-9.]+-[0-9]+$ ]]"
runs up browser
check "chrome off: no build" bash -c "! grep -q ' build ' '$T/log/docker.calls' && ! grep -q '^build ' '$T/log/docker.calls'"
check "chrome off: BROWSER_NODE_IMAGE cleared (env files cannot set it)" grep -qx "BROWSER_NODE_IMAGE=" "$T/log/docker.env"
printf 'BROWSER_NODE_CHROME=1\n' >"$T/etc/browser.env"
printf '%s\n' "$idok" >"$T/log/image.id"
runs up browser && called "build -t $ctag $T/opt/current/browser-stack/browser/node-chrome" \
    && ok "chrome on: up builds the release's node-chrome/Dockerfile here" || bad "chrome on: up build"
check "chrome on: the build comes before compose up" bash -c "grep -n '' '$T/log/docker.calls' | grep -E ':build |up -d' | head -1 | grep -q ':build '"
check "chrome on: compose gets the image id" grep -qx "BROWSER_NODE_IMAGE=$idok" "$T/log/docker.env"
check "chrome on: compose up with the release's files" called "-p happy-browser"
runs up vault
check "chrome on: up vault builds nothing" bash -c "! grep -q '^build ' '$T/log/docker.calls'"
runs logs browser bridge && called "logs --no-color --tail 200 bridge" && ! called "build -t" \
    && grep -qx "BROWSER_NODE_IMAGE=$idok" "$T/log/docker.env" && ok "chrome on: logs uses the built id, no build" || bad "chrome on: logs"
mv "$T/log/image.id" "$T/log/image.id.absent"
refused_late "chrome on: an image missing after its build" up browser
printf 'sha256:abc\n' >"$T/log/image.id"
refused_late "chrome on: an image id that is not sha256:<64 hex>" up browser
printf '%s\n' "$idok" >"$T/log/image.id"
printf 'BROWSER_NODE_CHROME=yes\n' >"$T/etc/browser.env"
refused "BROWSER_NODE_CHROME not 0 or 1 in browser.env" up browser
printf 'BROWSER_NODE_CHROME=0\n' >"$T/etc/browser.env"

check "journal: verbs only, no argument values" bash -c "! grep -Eq 'NAME=|bridge-client|happy-vault-data|filler' '$T/log/logger.calls' && grep -q 'verb=refused' '$T/log/logger.calls' && grep -q 'verb=up caller=' '$T/log/logger.calls'"

echo "== 4 root scripts refuse without root"
if [[ $EUID -ne 0 ]]; then
    for s in setup-root.sh teardown-root.sh; do
        check "$s: refuses without root" bash -c "bash '$SVC/$s' --dry-run 2>&1 | grep -q 'run with sudo'"
    done
    check "deploy-root.sh: refuses without root" bash -c "bash '$SVC/deploy-root.sh' $(printf '0%.0s' $(seq 1 40)) --dry-run 2>&1 | grep -q 'run with sudo'"
fi
# Settings: the keys and the values deploy-root.sh accepts (--check-settings, no root).
S="$T/settings"; mkdir -p "$S"
printf 'VAULT_DOMAIN=https://vault.example\n' >"$S/vault.env"
settings_ok() { printf '%s\n' "$@" >"$S/browser.env"; bash "$SVC/deploy-root.sh" --check-settings "$S" >/dev/null 2>&1; }
settings_check() { local n=$1 want=$2; shift 2
    if settings_ok "$@"; then [[ $want == ok ]] && ok "$n" || bad "$n (accepted)"; else [[ $want == no ]] && ok "$n" || bad "$n (refused)"; fi; }
settings_check "settings: chrome, zone and mode accepted" ok BROWSER_NODE_CHROME=1 EVIDENCE_TZ=America/Toronto SCREENSHOT_TIME_MODE=tab BRIDGE_PODS=1
settings_check "settings: BROWSER_NODE_CHROME=0" ok BROWSER_NODE_CHROME=0
settings_check "settings: EVIDENCE_TZ=Etc/GMT+5" ok EVIDENCE_TZ=Etc/GMT+5
settings_check "settings: EVIDENCE_TZ=UTC" ok EVIDENCE_TZ=UTC
settings_check "settings: EVIDENCE_TZ through a tzdata link (US/Eastern)" ok EVIDENCE_TZ=US/Eastern
settings_check "settings: BROWSER_NODE_CHROME=2 refused" no BROWSER_NODE_CHROME=2
settings_check "settings: BROWSER_NODE_CHROME=yes refused" no BROWSER_NODE_CHROME=yes
settings_check "settings: BROWSER_NODE_CHROME empty refused" no BROWSER_NODE_CHROME=
settings_check "settings: SCREENSHOT_TIME_MODE=window refused" no SCREENSHOT_TIME_MODE=window
settings_check "settings: EVIDENCE_TZ not a zone" no EVIDENCE_TZ=Mars/Olympus
settings_check "settings: EVIDENCE_TZ path traversal" no EVIDENCE_TZ=../../../etc/passwd
settings_check "settings: EVIDENCE_TZ traversal inside a name" no EVIDENCE_TZ=America/../../../etc/passwd
settings_check "settings: EVIDENCE_TZ absolute" no EVIDENCE_TZ=/etc/localtime
settings_check "settings: EVIDENCE_TZ a directory" no EVIDENCE_TZ=America
settings_check "settings: EVIDENCE_TZ a non-TZif file" no EVIDENCE_TZ=zone.tab
settings_check "settings: EVIDENCE_TZ posix/ copy refused" no EVIDENCE_TZ=posix/America/Toronto
settings_check "settings: EVIDENCE_TZ empty refused" no EVIDENCE_TZ=
settings_check "settings: no BROWSER_NODE_IMAGE" no "BROWSER_NODE_IMAGE=$idok"
check "deploy-root.sh: bad settings refused before the root check" bash -c "printf 'BROWSER_NODE_CHROME=2\n' >'$S/browser.env'; bash '$SVC/deploy-root.sh' $(printf '0%.0s' $(seq 1 40)) --settings '$S' 2>&1 | grep -q 'BROWSER_NODE_CHROME is 0 or 1'"
# make svc-settings: the new keys copied, EVIDENCE_TZ defaulted, a BROWSER_NODE_IMAGE dropped.
mkdir -p "$T/repo/selfhost/vault" "$T/repo/browser-stack/browser"
printf 'VAULT_DOMAIN=https://vault.example\n' >"$T/repo/selfhost/vault/.env"
printf 'BROWSER_NODE_CHROME=1\nSCREENSHOT_TIME_MODE=desktop\nBROWSER_NODE_IMAGE=evil:latest\nBRIDGE_LAN_BIND=192.168.0.2\n' >"$T/repo/browser-stack/browser/.env.browser"
make -s -f "$SVC/svc.mk" svc-settings SVC_REPO="$T/repo" SVC_SETTINGS="$T/svc-settings" >"$T/log/settings.out" 2>&1
check "svc-settings: BROWSER_NODE_CHROME and SCREENSHOT_TIME_MODE kept" bash -c "grep -qx BROWSER_NODE_CHROME=1 '$T/svc-settings/browser.env' && grep -qx SCREENSHOT_TIME_MODE=desktop '$T/svc-settings/browser.env'"
check "svc-settings: EVIDENCE_TZ defaulted to a zone" bash -c "grep -Eqx 'EVIDENCE_TZ=[A-Za-z][A-Za-z0-9_/+-]*' '$T/svc-settings/browser.env'"
check "svc-settings: BROWSER_NODE_IMAGE and the LAN listener dropped" bash -c "! grep -Eq '^(BROWSER_NODE_IMAGE|BRIDGE_LAN_BIND)=' '$T/svc-settings/browser.env'"
check "svc-settings: the result passes deploy-root's check" grep -q 'accepted' "$T/log/settings.out"
check "deploy-root.sh: refuses a short sha" bash -c "bash '$SVC/deploy-root.sh' abc123 2>&1 | grep -q usage"
check "setup-root.sh: refuses a short sha" bash -c "bash '$SVC/setup-root.sh' --commit abc 2>&1 | grep -q '40-hex'"

echo
echo "svc tests: $pass passed, $fail failed (work tree $T)"
[[ $fail -eq 0 ]]
