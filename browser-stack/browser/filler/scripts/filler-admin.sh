#!/usr/bin/env bash
# The secret filler's admin commands. They run as the happy-filler account,
# never with sudo:
#
#   su - happy-filler
#   filler-admin <command> [KEY=value ...]
#
# ~happy-filler/bin/filler-admin links to the installed release's copy of this
# script (/srv/happy-filler/current/app/scripts/filler-admin.sh), which prep
# cannot change. `make -C /home/prep/happy/selfhost filler-<command>` as
# happy-filler runs that same installed script, but the Makefile it reads lives
# in prep's writable tree; typing filler-admin is the stricter path.
#
#   install COMMIT=<sha>     deploy a reviewed commit from prep's repo into
#                            releases/<sha>, point current at it, upgrade the
#                            policy once, install and enable the user unit
#   up | down | restart | lock | logs | unit-status
#   init                     directories and an empty policy (fresh install)
#   token-issue NAME=bridge-client|vault-client [FILLER_ROTATE=1]
#                            a new client token: its SHA-256 to secrets/, the
#                            plaintext once to outbox/<NAME>-token (0640) for
#                            prep's make filler-token-take
#   controller-token-take    inbox/controller-token (from prep's make
#                            filler-controller-token-give) -> secrets/ 0400
#   enroll                   (terminal) enroll with the agent's vault account
#   seed-policy [FILLER_DEFAULT_CLIENT=agent]  seed an empty policy
#   policy-edit              back up, edit a copy, validate, then swap it in
#   items                    the agent account's logins (no values)
#   outbox-clear             move tokens prep has not taken to trash/
#   setup COMMIT=<sha>       a fresh install: init, install, the tokens,
#                            seed-policy, enroll, up, items
#
# Layout (account-setup.sh, the one step that needs root, creates the account
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
[[ -n "$cmd" ]] || { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
for a in "$@"; do
  case "$a" in
    COMMIT=*|FILLER_ROTATE=*|FILLER_DEFAULT_CLIENT=*|NAME=*) export "${a?}" ;;
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

do_install() {
  need_layout
  local commit="${COMMIT:-}"
  [[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || die "COMMIT=<sha> is required: the hex sha of the commit you reviewed"
  # A mirror of prep's repo in this account's home. A fetch re-hashes every
  # object it receives, so what is deployed is exactly the reviewed commit,
  # even though prep could change the files under its own .git. The fetch runs
  # git-upload-pack in prep's repo; repo-level config cannot hook it
  # (uploadpack.packObjectsHook is read from system/global config only).
  local mirror="$HOME/src.git"
  local g=(git --no-pager -c "safe.directory=$REPO" -c "safe.directory=$REPO/.git" --git-dir="$mirror")
  [[ -d "$mirror" ]] || git init -q --bare "$mirror"
  # git 2.25 (Ubuntu 20.04) reads safe.directory from global config only and
  # git-upload-pack does not inherit -c, so trust prep's repo in this
  # account's own ~/.gitconfig (that one path, nothing else).
  local d
  for d in "$REPO" "$REPO/.git"; do
    git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$d" || git config --global --add safe.directory "$d"
  done
  [[ -r "$REPO/.git" || -r "$REPO/HEAD" ]] || die "cannot read $REPO as $ACCOUNT"
  echo "filler-admin install: fetching $REPO"
  "${g[@]}" fetch -q --no-tags "file://$REPO" '+refs/heads/*:refs/prep/*' || die "git fetch from $REPO failed"
  local sha; sha="$("${g[@]}" rev-parse -q --verify "$commit^{commit}")" || die "$commit is not on a branch of $REPO"
  [[ "$sha" == "$commit"* ]] || die "$commit is not a commit sha"
  local rel="$ROOT/releases/$sha"
  if [[ -e "$rel" ]]; then
    echo "filler-admin install: $sha already installed"
  else
    "${g[@]}" cat-file -e "$sha:$APP_SUBDIR/server.mjs" 2>/dev/null || APP_SUBDIR=selfhost/browser/filler
    local stage; stage="$(mktemp -d "$ROOT/releases/.stage-XXXXXX")"
    "${g[@]}" archive --format=tar "$sha" "$APP_SUBDIR" | tar -x --no-same-owner --no-same-permissions -C "$stage"
    if [[ ! -f "$stage/$APP_SUBDIR/server.mjs" || ! -f "$stage/$APP_SUBDIR/systemd/$UNIT" ]]; then
      mv -T "$stage" "$ROOT/releases/.failed-$sha-$TS"; die "$sha has no systemd filler ($APP_SUBDIR/server.mjs, systemd/$UNIT)"
    fi
    mkdir "$stage/rel"
    mv -T "$stage/$APP_SUBDIR" "$stage/rel/app"
    printf '%s\n' "$sha" >"$stage/rel/COMMIT"
    chmod -R u+rwX,go+rX "$stage/rel"
    # Moving a directory needs it writable (its ".." changes), so a-w comes after the move.
    mv -T "$stage/rel" "$rel"
    chmod -R a-w "$rel"
    mv -T "$stage" "$(trash_dir)/install-stage-$sha"
    echo "filler-admin install: installed $sha"
  fi
  local prev; prev="$(readlink "$ROOT/current" 2>/dev/null || true)"
  ln -sfn "releases/$sha" "$ROOT/current.new"; mv -T "$ROOT/current.new" "$ROOT/current"
  echo "filler-admin install: current -> releases/$sha${prev:+ (was $prev)}"

  # Once: give a policy from before the vault tools its manage and pipe_targets.
  local pol="$ROOT/policy.json"
  if [[ -s "$pol" && -f "$ROOT/current/app/scripts/policy-upgrade.mjs" ]]; then
    local up rc=0; up="$(mktemp "$ROOT/.policy-up.XXXXXX")"
    "$NODE" "$ROOT/current/app/scripts/policy-upgrade.mjs" "$pol" >"$up" || rc=$?
    if [[ $rc -eq 0 && -s "$up" ]]; then
      cp -p "$pol" "$ROOT/policy-backups/policy.$TS.json"
      chmod 0640 "$up"; mv -T "$up" "$pol"
      echo "filler-admin install: policy upgraded for the vault tools; the old one is in policy-backups/"
    else
      mv -T "$up" "$(trash_dir)/policy-upgrade-output"
      if [[ $rc -eq 3 ]]; then echo "filler-admin install: policy already has pipe_targets; left as is"
      else echo "filler-admin install: WARNING: policy upgrade failed (exit $rc); policy left as is (filler-admin policy-edit)" >&2; fi
    fi
  fi

  # The user unit, from the release.
  local udir="$HOME/.config/systemd/user" src="$ROOT/current/app/systemd/$UNIT"
  install -d -m 0700 "$HOME/.config" "$HOME/.config/systemd"; install -d -m 0755 "$udir"
  if [[ -e "$udir/$UNIT" ]] && ! cmp -s "$src" "$udir/$UNIT"; then mv -T "$udir/$UNIT" "$(trash_dir)/$UNIT"; fi
  if [[ ! -e "$udir/$UNIT" ]]; then install -m 0644 "$src" "$udir/$UNIT"; echo "filler-admin install: installed $udir/$UNIT"; fi
  sysctl_user daemon-reload
  sysctl_user enable -q "$UNIT"
  install -d -m 0700 "$HOME/bin"
  ln -sfn "$ROOT/current/app/scripts/filler-admin.sh" "$HOME/bin/filler-admin"
  echo "filler-admin install: done; run filler-admin restart to switch the running filler to it"
}

do_enroll() {
  need_layout; need_release
  [[ -t 0 ]] || die "needs a terminal"
  open_secrets
  FILLER_HOME="$ROOT" VAULT_URL="$VAULT_URL" "$NODE" "$ROOT/current/app/enroll.mjs"
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
  FILLER_HOME="$ROOT" VAULT_URL="$VAULT_URL" "$NODE" "$ROOT/current/app/enroll.mjs" --items
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
    echo "== install $COMMIT"; do_install
    if [[ ! -s "$ROOT/secrets/controller-token" ]]; then echo "== controller-token-take"; do_controller_token_take; fi
    [[ -s "$ROOT/secrets/client-token.sha256" ]] || { echo "== token-issue NAME=bridge-client"; NAME=bridge-client do_token_issue; }
    [[ -s "$ROOT/secrets/vault-client-token.sha256" ]] || { echo "== token-issue NAME=vault-client"; NAME=vault-client do_token_issue; }
    echo "== seed-policy"; do_seed_policy
    echo "== enroll"; do_enroll; trap - EXIT; chmod 0500 "$ROOT/secrets"
    echo "== up"; sysctl_user enable -q "$UNIT"; sysctl_user restart "$UNIT"; wait_healthy
    echo "== the agent account's logins"; do_items
    echo "== next, as prep: make filler-token-take (if tokens were issued), then make filler-status" ;;
  *) die "unknown command (filler-admin with no command lists them)" ;;
esac
