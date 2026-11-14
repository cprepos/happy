#!/usr/bin/env bash
# The secret filler's admin commands. They run as the happy-filler account,
# never with sudo:
#
#   su - happy-filler
#   filler-admin <command> [KEY=value ...]
#
# ~happy-filler/bin/filler-admin links to the installed release's copy of this
# script (/srv/happy-filler/current/app/scripts/filler-admin.sh), which prep
# cannot change (scripts/filler-install.sh makes the link). `make -C
# /home/prep/happy/selfhost filler-<command>` as happy-filler runs that same
# installed script, but the Makefile it reads lives in prep's writable tree;
# typing filler-admin is the stricter path.
#
#   install COMMIT=<sha>     scripts/filler-install.sh: deploy a reviewed commit
#                            from prep's repo into releases/<sha>, point current
#                            at it, upgrade and check the policy, install and
#                            enable the user unit, restart it
#   up | down | restart | lock | logs | unit-status
#   init                     directories and an empty policy (fresh install)
#   token-issue NAME=bridge-client|vault-client [FILLER_ROTATE=1]
#                            a new client token: its SHA-256 to secrets/, the
#                            plaintext once to outbox/<NAME>-token (0640) for
#                            prep's make filler-token-take
#   controller-token-take    inbox/controller-token (from prep's make
#                            filler-controller-token-give) -> secrets/ 0400
#   enroll [BACKEND=shared] [VAULT_URL=...] [FILLER_AGENT_EMAIL=...]
#                            (terminal) enroll with the agent's vault account;
#                            backend shared writes secrets/, any other name
#                            secrets/<name>/ (the policy's backends.<name>)
#   seed-policy [FILLER_DEFAULT_CLIENT=agent]  seed an empty policy
#   policy-edit              back up, edit a copy, validate, then swap it in
#   policy-upgrade           once per step: give an older policy what it lacks
#                            (pipe_targets and manage; backends), backup kept
#   check-policy             validate policy.json with the installed release
#   items                    the agent account's logins (no values)
#   outbox-clear             move tokens prep has not taken to trash/
#   setup COMMIT=<sha>       a fresh install: init, install, the tokens,
#                            seed-policy, enroll, restart, items
#
# Layout (filler-account-setup.sh, the one step that needs root, creates the account
# and hands this tree to it; everything after is done here, as happy-filler):
#   /srv/happy-filler/                happy-filler 0755
#     releases/<sha>/                 read-only (a-w); current -> releases/<sha>
#     secrets/                        happy-filler 0500, files 0400
#     state/  policy-backups/  trash/ happy-filler 0700
#     policy.json                     happy-filler 0640
#     audit/                          happy-filler:prep 2750, files 0640
#     outbox/                         happy-filler:prep 2770: tokens for prep, 0640
#     inbox/                          happy-filler:prep 3730: prep drops controller-token here
# Prints no secrets.
set -euo pipefail
ACCOUNT=happy-filler
ROOT=/srv/happy-filler
UNIT=happy-filler.service
NODE=/usr/bin/node
REPO="${FILLER_REPO:-/home/prep/happy}"
VAULT_URL="${VAULT_URL:-http://127.0.0.1:8222}"
FILLER_URL="${FILLER_URL:-http://127.0.0.1:6091}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
# Where the filler sits in a commit: browser-stack/browser/filler, or selfhost/browser/filler
# in commits from before the browser stack had its own folder (set per commit in install).
APP_SUBDIR=browser-stack/browser/filler

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

cmd="${1:-}"
die() { echo "filler-admin${cmd:+ $cmd}: $*" >&2; exit 1; }

# The guard comes first, before any argument is looked at: as any other
# account (prep, root) every command stops here.
if [[ "$(id -un)" != "$ACCOUNT" ]]; then
  echo "filler-admin: run as $ACCOUNT, not $(id -un):" >&2
  echo "  su - $ACCOUNT" >&2
  echo "  filler-admin ${cmd:-<command>}   (or: make -C $REPO/selfhost filler-${cmd:-<command>})" >&2
  exit 1
fi
[[ -n "$cmd" ]] || { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
for a in "$@"; do
  case "$a" in
    COMMIT=*|FILLER_ROTATE=*|FILLER_DEFAULT_CLIENT=*|NAME=*|BACKEND=*|VAULT_URL=*|FILLER_AGENT_EMAIL=*) export "${a?}" ;;
    *) die "unknown argument ${a%%=*}" ;;
  esac
done

umask 077
# systemctl --user needs this account's runtime dir; su keeps the caller's.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [[ -S "$XDG_RUNTIME_DIR/bus" ]]; then export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"; else unset DBUS_SESSION_BUS_ADDRESS; fi
sysctl_user() { systemctl --user "$@"; }

need_layout() {
  [[ -d "$ROOT" && -O "$ROOT" && -d "$ROOT/secrets" && -O "$ROOT/secrets" && -d "$ROOT/audit" ]] \
    || die "$ROOT is not set up for $ACCOUNT yet; as your own account run, once: make filler-account-setup COMMIT=<sha>"
}
need_release() { [[ -f "$ROOT/current/app/server.mjs" ]] || die "no release installed; run filler-admin install COMMIT=<sha>"; }

trash_dir() { local d="$ROOT/trash/$TS"; install -d -m 0700 "$ROOT/trash" "$d"; printf '%s' "$d"; }

open_secrets() { chmod 0700 "$ROOT/secrets"; trap 'chmod 0500 "$ROOT/secrets"' EXIT; }

# put <name> <source file>: install as secrets/<name> 0400, moving a different old one to secrets/old-<ts>/.
put() {
  local dst="$ROOT/secrets/$1"
  if [[ -e "$dst" ]] && ! cmp -s "$2" "$dst"; then
    install -d -m 0700 "$ROOT/secrets/old-$TS"; mv "$dst" "$ROOT/secrets/old-$TS/"
  fi
  if [[ ! -e "$dst" ]]; then install -m 0400 "$2" "$dst"; echo "filler-admin $cmd: wrote secrets/$1"; fi
}

wait_healthy() {
  local i out
  for i in $(seq 1 40); do
    if out="$(curl -fs --max-time 2 "$FILLER_URL/healthz" 2>/dev/null)"; then echo "healthz: $out"; return 0; fi
    sleep 0.5
  done
  echo "healthz: unreachable after 20 s; see filler-admin logs" >&2
  return 1
}

check_policy() { # check_policy <file>
  [[ -f "$ROOT/current/app/server.mjs" ]] || return 0
  "$NODE" "$ROOT/current/app/server.mjs" --check-policy "$1"
}

do_init() {
  need_layout
  [[ -d "$ROOT/outbox" && -d "$ROOT/inbox" ]] || die "outbox/ and inbox/ are missing; as your own account re-run make filler-account-setup COMMIT=<sha>"
  install -d -m 0700 "$ROOT/state" "$ROOT/policy-backups" "$ROOT/trash"
  local pol="$ROOT/policy.json"
  if [[ ! -e "$pol" ]]; then
    local t; t="$(mktemp "$ROOT/.policy.XXXXXX")"
    printf '{\n  "version": 1,\n  "clients": {},\n  "chats": {}\n}\n' >"$t"; chmod 0640 "$t"; mv -T "$t" "$pol"
    echo "filler-admin init: wrote an empty $pol (fill it with filler-admin seed-policy or policy-edit)"
  fi
  local f
  for f in controller-token client-token.sha256 vault-client-token.sha256; do
    [[ -s "$ROOT/secrets/$f" ]] || echo "filler-admin init: secrets/$f missing; $(next_for "$f")"
  done
  echo "filler-admin init: $ROOT ready"
}

next_for() {
  case "$1" in
    controller-token) echo "as prep: make filler-controller-token-give, then here: filler-admin controller-token-take" ;;
    client-token.sha256) echo "filler-admin token-issue NAME=bridge-client" ;;
    vault-client-token.sha256) echo "filler-admin token-issue NAME=vault-client" ;;
  esac
}

# token-issue NAME=bridge-client|vault-client: a new client token. The filler
# keeps only its SHA-256 (secrets/); the plaintext goes once to
# outbox/<NAME>-token (group prep, 0640) for prep's make filler-token-take.
# An existing token is replaced only with FILLER_ROTATE=1 (its hash moves to
# secrets/old-<ts>/).
do_token_issue() {
  need_layout
  local name="${NAME:-}" sha
  case "$name" in
    bridge-client) sha=client-token.sha256 ;;
    vault-client) sha=vault-client-token.sha256 ;;
    *) die "NAME=bridge-client or NAME=vault-client" ;;
  esac
  [[ -d "$ROOT/outbox" ]] || die "outbox/ is missing; as your own account re-run make filler-account-setup COMMIT=<sha>"
  if [[ -s "$ROOT/secrets/$sha" && "${FILLER_ROTATE:-0}" != 1 ]]; then
    die "$name already has a token (secrets/$sha); FILLER_ROTATE=1 replaces it, and the old one stops working"
  fi
  install -d -m 0700 "$ROOT/trash"
  local work tok out="$ROOT/outbox/$name-token" ht
  work="$(mktemp -d "$ROOT/trash/.issue-XXXXXX")"
  tok="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  # Made inside outbox/ so the setgid bit gives it group prep.
  ht="$(mktemp "$ROOT/outbox/.$name.XXXXXX")"
  printf '%s' "$tok" >"$ht"; chmod 0640 "$ht"
  printf '%s' "$tok" | sha256sum | cut -d' ' -f1 >"$work/$sha"
  tok=""
  open_secrets
  put "$sha" "$work/$sha"
  chmod 0500 "$ROOT/secrets"; trap - EXIT
  if [[ -e "$out" || -L "$out" ]]; then mv -T "$out" "$(trash_dir)/outbox-$name-token"; fi
  mv -T "$ht" "$out"
  mv -T "$work" "$(trash_dir)/issue-$name"
  if cmp -s "$ROOT/secrets/client-token.sha256" "$ROOT/secrets/vault-client-token.sha256"; then
    echo "filler-admin token-issue: WARNING: the two client tokens are the same; issue one again with FILLER_ROTATE=1" >&2
  fi
  echo "filler-admin token-issue: wrote $out; as prep run make filler-token-take, then filler-admin restart here"
}

# controller-token-take: the browser controller token prep dropped in inbox/
# (make filler-controller-token-give) becomes secrets/controller-token (0400);
# the inbox file moves to trash/.
do_controller_token_take() {
  need_layout
  need_release
  local in="$ROOT/inbox/controller-token" work
  [[ -e "$in" || -L "$in" ]] || die "nothing in inbox/; as prep run make filler-controller-token-give first"
  install -d -m 0700 "$ROOT/trash"
  work="$(mktemp -d "$ROOT/trash/.take-XXXXXX")"
  "$NODE" "$ROOT/current/app/scripts/handoff-copy.mjs" "$in" "$work/controller-token" --mode 0400 \
    || die "inbox/controller-token refused (see above); drop it again with make filler-controller-token-give"
  open_secrets
  put controller-token "$work/controller-token"
  chmod 0500 "$ROOT/secrets"; trap - EXIT
  mv -T "$in" "$(trash_dir)/inbox-controller-token"
  mv -T "$work" "$(trash_dir)/take-controller-token"
  echo "filler-admin controller-token-take: done; filler-admin restart uses it"
}

# The install itself is scripts/filler-install.sh (this release's copy).
do_install() {
  need_layout
  [[ -n "${COMMIT:-}" ]] || die "COMMIT=<sha> is required: the hex sha of the commit you reviewed"
  FILLER_REPO="$REPO" FILLER_NO_RESTART="${FILLER_NO_RESTART:-0}" bash "$HERE/filler-install.sh" COMMIT="$COMMIT"
}

do_policy_upgrade() {
  need_layout; need_release
  local pol="$ROOT/policy.json"
  [[ -s "$pol" ]] || die "no policy; run filler-admin init first"
  local up rc=0; up="$(mktemp "$ROOT/.policy-up.XXXXXX")"
  "$NODE" "$ROOT/current/app/scripts/policy-upgrade.mjs" "$pol" >"$up" || rc=$?
  if [[ $rc -eq 0 && -s "$up" ]]; then
    install -d -m 0700 "$ROOT/policy-backups"
    cp -p "$pol" "$ROOT/policy-backups/policy.$TS.json"
    chmod 0640 "$up"; mv -T "$up" "$pol"
    echo "filler-admin policy-upgrade: upgraded policy.json (the old one is policy-backups/policy.$TS.json)"
    check_policy "$pol"
  else
    mv -T "$up" "$(trash_dir)/policy-upgrade-output"
    if [[ $rc -eq 3 ]]; then echo "filler-admin policy-upgrade: policy.json is up to date (it has pipe_targets and backends); left as is"
    else die "the upgrade failed (exit $rc); policy.json left as is (filler-admin policy-edit)"; fi
  fi
}

# enroll [BACKEND=<name>]: the shared backend's keys go to secrets/ itself,
# another backend's to secrets/<name>/ (lib/policy.mjs BACKEND_NAME).
do_enroll() {
  need_layout; need_release
  [[ -t 0 ]] || die "needs a terminal"
  local backend="${BACKEND:-shared}" dir="$ROOT/secrets"
  [[ "$backend" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "bad BACKEND name"
  open_secrets
  if [[ "$backend" != shared ]]; then
    dir="$ROOT/secrets/$backend"
    [[ -d "$dir" ]] || install -d -m 0500 "$dir"
    chmod 0700 "$dir"
    trap 'chmod 0500 "$ROOT/secrets/$BACKEND" "$ROOT/secrets"' EXIT
  fi
  echo "filler-admin enroll: backend $backend, keys to ${dir#$ROOT/}/, vault $VAULT_URL"
  FILLER_HOME="$ROOT" FILLER_ENROLL_DIR="$dir" VAULT_URL="$VAULT_URL" ${FILLER_AGENT_EMAIL:+FILLER_AGENT_EMAIL="$FILLER_AGENT_EMAIL"} \
    "$NODE" "$ROOT/current/app/lib/providers/vaultwarden/enroll.mjs"
  echo "filler-admin enroll: restart the filler to use the new keys: filler-admin restart"
}

do_seed_policy() {
  need_layout
  local pol="$ROOT/policy.json" client="${FILLER_DEFAULT_CLIENT:-agent}" norm=""
  [[ "$client" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || die "bad client name"
  [[ -e "$pol" ]] && norm="$(tr -d ' \t\r\n' <"$pol")"
  if [[ -n "$norm" && "$norm" != '{"version":1,"clients":{},"chats":{}}' ]]; then
    echo "filler-admin seed-policy: $pol already has content; left as is"; return 0
  fi
  install -d -m 0700 "$ROOT/policy-backups"
  [[ -e "$pol" ]] && cp -p "$pol" "$ROOT/policy-backups/policy.$TS.json"
  local t; t="$(mktemp "$ROOT/.policy.XXXXXX")"
  printf '{"version":1,"default_client":"%s","clients":{"%s":{"all_items":true,"secrets":{},"manage":{"create":true,"update":true,"remove":true,"compare":true,"pipe":[]}}},"chats":{},"pipe_targets":{}}\n' "$client" "$client" >"$t"
  chmod 0640 "$t"; mv -T "$t" "$pol"
  echo "filler-admin seed-policy: wrote $pol: default_client \"$client\" with all_items and manage"
  check_policy "$pol"
}

do_policy_edit() {
  need_layout; need_release
  [[ -t 0 ]] || die "needs a terminal"
  local pol="$ROOT/policy.json"
  [[ -e "$pol" ]] || die "no policy; run filler-admin init first"
  install -d -m 0700 "$ROOT/policy-backups"
  cp -p "$pol" "$ROOT/policy-backups/policy.$TS.json"
  local t; t="$(mktemp "$ROOT/.policy-edit.XXXXXX")"
  cp "$pol" "$t"; chmod 0640 "$t"
  local ed="${VISUAL:-${EDITOR:-vi}}" ans
  while :; do
    $ed "$t"
    if cmp -s "$t" "$pol"; then mv -T "$t" "$(trash_dir)/policy-edit-unchanged.json"; echo "filler-admin policy-edit: unchanged"; return 0; fi
    chmod 0640 "$t"
    if check_policy "$t"; then
      mv -T "$t" "$pol"
      echo "filler-admin policy-edit: saved (the old one is policy-backups/policy.$TS.json); the running filler reloads it on its own"
      return 0
    fi
    read -r -p "the edit is invalid and was not saved; e to edit it again, q to quit (it stays in $t): " ans
    [[ "$ans" == e ]] || { echo "filler-admin policy-edit: policy.json unchanged; your edit is in $t" >&2; return 1; }
  done
}

do_items() {
  need_layout; need_release
  FILLER_HOME="$ROOT" VAULT_URL="$VAULT_URL" "$NODE" "$ROOT/current/app/lib/providers/vaultwarden/enroll.mjs" --items
}

do_outbox_clear() {
  need_layout
  local f n=0 d
  for f in "$ROOT/outbox"/* "$ROOT/outbox"/.[!.]*; do
    [[ -e "$f" || -L "$f" ]] || continue
    d="$(trash_dir)/outbox"; install -d -m 0700 "$d"; mv -T "$f" "$d/$(basename "$f")"; n=$((n + 1))
  done
  echo "filler-admin outbox-clear: moved $n file(s) to ${d:-trash/}"
}

case "$cmd" in
  init) do_init ;;
  install) do_install ;;
  enroll) do_enroll ;;
  policy-upgrade) do_policy_upgrade ;;
  check-policy) need_layout; need_release; check_policy "$ROOT/policy.json" || die "policy.json is invalid" ;;
  seed-policy) do_seed_policy ;;
  policy-edit) do_policy_edit ;;
  up) need_layout; need_release; sysctl_user enable -q "$UNIT"; sysctl_user start "$UNIT"; wait_healthy ;;
  restart) need_layout; need_release; sysctl_user restart "$UNIT"; wait_healthy ;;
  down|lock)
    sysctl_user disable -q "$UNIT" 2>/dev/null || true
    sysctl_user stop "$UNIT"
    echo "filler-admin $cmd: stopped (its keys left memory) and disabled at boot; filler-admin up starts it again" ;;
  logs) journalctl --user -u "$UNIT" -n 200 -f ;;
  unit-status) sysctl_user --no-pager status "$UNIT" || true ;;
  items) do_items ;;
  outbox-clear) do_outbox_clear ;;
  token-issue) do_token_issue ;;
  controller-token-take) do_controller_token_take ;;
  setup)
    [[ -n "${COMMIT:-}" ]] || die "COMMIT=<sha> is required"
    echo "== init"; do_init
    echo "== install $COMMIT"; FILLER_NO_RESTART=1 do_install
    if [[ ! -s "$ROOT/secrets/controller-token" ]]; then echo "== controller-token-take"; do_controller_token_take; fi
    [[ -s "$ROOT/secrets/client-token.sha256" ]] || { echo "== token-issue NAME=bridge-client"; NAME=bridge-client do_token_issue; }
    [[ -s "$ROOT/secrets/vault-client-token.sha256" ]] || { echo "== token-issue NAME=vault-client"; NAME=vault-client do_token_issue; }
    echo "== seed-policy"; do_seed_policy
    echo "== enroll"; do_enroll; trap - EXIT; chmod 0500 "$ROOT/secrets"
    echo "== restart"; sysctl_user enable -q "$UNIT"; sysctl_user restart "$UNIT"; wait_healthy
    echo "== the agent account's logins"; do_items
    echo "== next, as prep: make filler-token-take (if tokens were issued), then make filler-status" ;;
  *) die "unknown command (filler-admin with no command lists them)" ;;
esac
