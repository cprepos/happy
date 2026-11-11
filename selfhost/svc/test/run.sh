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

check "journal: verbs only, no argument values" bash -c "! grep -Eq 'NAME=|bridge-client|happy-vault-data|filler' '$T/log/logger.calls' && grep -q 'verb=refused' '$T/log/logger.calls' && grep -q 'verb=up caller=' '$T/log/logger.calls'"

echo "== 4 root scripts refuse without root"
if [[ $EUID -ne 0 ]]; then
    for s in setup-root.sh teardown-root.sh; do
        check "$s: refuses without root" bash -c "bash '$SVC/$s' --dry-run 2>&1 | grep -q 'run with sudo'"
    done
    check "deploy-root.sh: refuses without root" bash -c "bash '$SVC/deploy-root.sh' $(printf '0%.0s' $(seq 1 40)) --dry-run 2>&1 | grep -q 'run with sudo'"
fi
check "deploy-root.sh: refuses a short sha" bash -c "bash '$SVC/deploy-root.sh' abc123 2>&1 | grep -q usage"
check "setup-root.sh: refuses a short sha" bash -c "bash '$SVC/setup-root.sh' --commit abc 2>&1 | grep -q '40-hex'"

echo
echo "svc tests: $pass passed, $fail failed (work tree $T)"
[[ $fail -eq 0 ]]
