#!/usr/bin/env bash
# Install a reviewed commit of the secret filler on bare metal, as the
# happy-filler account (no sudo; the account and /srv/happy-filler come from
# make filler-account-setup, the one step that needs root):
#
#   su - happy-filler
#   make -C /home/prep/happy/selfhost filler-install COMMIT=<sha>
#   (or: filler-admin install COMMIT=<sha>)
#
# The make target runs this script as it is in COMMIT, taken from
# happy-filler's own mirror of prep's repo; filler-admin install runs the
# installed release's copy. Either way it:
#
#   1 fetches prep's repo into ~happy-filler/src.git (a fetch re-hashes every
#     object, so what is deployed is exactly the reviewed commit)
#   2 stages releases/<sha>: app/ (the filler's tree at COMMIT) and COMMIT;
#     dependencies only from package-lock.json (npm ci --omit=dev
#     --ignore-scripts); then read-only (a-w)
#   3 switches current -> releases/<sha> (the previous target is printed: the
#     rollback is filler-install of that sha, or ln -sfn by hand)
#   4 upgrades the policy once if it lacks pipe_targets or backends (backup in
#     policy-backups/) and checks it with the new release; a policy the new
#     release rejects switches current back and stops
#   5 installs the user unit from the release (a different old one goes to
#     trash/), daemon-reload, enable
#   6 points ~/bin/filler-admin at the release's scripts/filler-admin.sh (an old
#     different shim goes to trash/)
#   7 restarts the unit and waits for /healthz
#
# Nothing is deleted: replaced files go to /srv/happy-filler/trash/<ts>/.
# FILLER_NO_RESTART=1 skips step 7 (filler-admin setup restarts later itself).
set -euo pipefail
ACCOUNT=happy-filler
ROOT=/srv/happy-filler
UNIT=happy-filler.service
NODE=/usr/bin/node
NPM=/usr/bin/npm
REPO="${FILLER_REPO:-/home/prep/happy}"
FILLER_URL="${FILLER_URL:-http://127.0.0.1:6091}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
# Where the filler sits in a commit: browser-stack/browser/filler, or
# selfhost/browser/filler in commits from before the browser stack had its own folder.
APP_SUBDIR=browser-stack/browser/filler

die() { echo "filler-install: $*" >&2; exit 1; }
say() { echo "filler-install: $*"; }

if [[ "$(id -un)" != "$ACCOUNT" ]]; then
  echo "filler-install: run as $ACCOUNT, not $(id -un) (no sudo):" >&2
  echo "  su - $ACCOUNT" >&2
  echo "  make -C $REPO/selfhost filler-install COMMIT=<sha>" >&2
  exit 1
fi
for a in "$@"; do
  case "$a" in
    COMMIT=*) COMMIT="${a#COMMIT=}" ;;
    *) die "unknown argument ${a%%=*}" ;;
  esac
done
commit="${COMMIT:-}"
[[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || die "COMMIT=<sha> is required: the hex sha of the commit you reviewed"
[[ -d "$ROOT" && -O "$ROOT" && -d "$ROOT/secrets" && -d "$ROOT/releases" ]] \
  || die "$ROOT is not set up for $ACCOUNT yet; as your own account run, once: make filler-account-setup COMMIT=<sha>"

umask 077
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [[ -S "$XDG_RUNTIME_DIR/bus" ]]; then export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"; else unset DBUS_SESSION_BUS_ADDRESS; fi
trash_dir() { local d="$ROOT/trash/$TS"; install -d -m 0700 "$ROOT/trash" "$d"; printf '%s' "$d"; }

# 1 -------------------------------------------------------------- fetch
mirror="$HOME/src.git"
g=(git --no-pager -c "safe.directory=$REPO" -c "safe.directory=$REPO/.git" --git-dir="$mirror")
[[ -d "$mirror" ]] || git init -q --bare "$mirror"
# git 2.25 reads safe.directory from global config only and git-upload-pack
# does not inherit -c, so trust prep's repo in this account's ~/.gitconfig
# (that one path, nothing else).
for d in "$REPO" "$REPO/.git"; do
  git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$d" || git config --global --add safe.directory "$d"
done
[[ -r "$REPO/.git" || -r "$REPO/HEAD" ]] || die "cannot read $REPO as $ACCOUNT"
say "fetching $REPO"
"${g[@]}" fetch -q --no-tags "file://$REPO" '+refs/heads/*:refs/prep/*' || die "git fetch from $REPO failed"
sha="$("${g[@]}" rev-parse -q --verify "$commit^{commit}")" || die "$commit is not on a branch of $REPO"
[[ "$sha" == "$commit"* ]] || die "$commit is not a commit sha"

# 2 -------------------------------------------------------------- stage
rel="$ROOT/releases/$sha"
if [[ -e "$rel" ]]; then
  say "$sha already installed"
else
  "${g[@]}" cat-file -e "$sha:$APP_SUBDIR/server.mjs" 2>/dev/null || APP_SUBDIR=selfhost/browser/filler
  stage="$(mktemp -d "$ROOT/releases/.stage-XXXXXX")"
  "${g[@]}" archive --format=tar "$sha" "$APP_SUBDIR" | tar -x --no-same-owner --no-same-permissions -C "$stage"
  app="$stage/$APP_SUBDIR"
  if [[ ! -f "$app/server.mjs" || ! -f "$app/systemd/$UNIT" || ! -f "$app/scripts/filler-admin.sh" ]]; then
    mv -T "$stage" "$(trash_dir)/install-failed-$sha"
    die "$sha has no bare-metal filler ($APP_SUBDIR/server.mjs, systemd/$UNIT, scripts/filler-admin.sh)"
  fi
  # Dependencies only from the lockfile: exact versions, integrity-checked, no
  # install scripts, no dev dependencies. npm's cache stays in the stage.
  if [[ -f "$app/package-lock.json" ]]; then
    say "npm ci --omit=dev (from package-lock.json)"
    if ! (cd "$app" && HOME="$stage" npm_config_cache="$stage/npm-cache" \
          "$NODE" "$(readlink -f "$NPM")" ci --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error); then
      mv -T "$stage" "$(trash_dir)/install-failed-$sha"; die "npm ci failed; nothing switched"
    fi
  elif grep -q '"dependencies"' "$app/package.json"; then
    mv -T "$stage" "$(trash_dir)/install-failed-$sha"; die "package.json has dependencies but no package-lock.json"
  fi
  mkdir "$stage/rel"
  mv -T "$app" "$stage/rel/app"
  printf '%s\n' "$sha" >"$stage/rel/COMMIT"
  chmod -R u+rwX,go+rX "$stage/rel"
  # Moving a directory needs it writable (its ".." changes), so a-w comes after the move.
  mv -T "$stage/rel" "$rel"
  chmod -R a-w "$rel"
  mv -T "$stage" "$(trash_dir)/install-stage-$sha"
  say "installed releases/$sha"
fi

# 3 -------------------------------------------------------------- switch
prev="$(readlink "$ROOT/current" 2>/dev/null || true)"
ln -sfn "releases/$sha" "$ROOT/current.new"; mv -T "$ROOT/current.new" "$ROOT/current"
say "current -> releases/$sha${prev:+ (was $prev)}"
switch_back() {
  if [[ -n "$prev" && "$prev" != "releases/$sha" ]]; then
    ln -sfn "$prev" "$ROOT/current.new"; mv -T "$ROOT/current.new" "$ROOT/current"; say "current -> $prev again"
  fi
}

# 4 -------------------------------------------------------------- policy
admin="$ROOT/current/app/scripts/filler-admin.sh"
if [[ -s "$ROOT/policy.json" ]]; then
  bash "$admin" policy-upgrade || { switch_back; die "the policy upgrade failed; the unit was not touched"; }
  bash "$admin" check-policy || { switch_back; die "the new release rejects policy.json; fix it (filler-admin policy-edit) and install again"; }
fi

# 5 -------------------------------------------------------------- unit
udir="$HOME/.config/systemd/user" src="$ROOT/current/app/systemd/$UNIT"
install -d -m 0700 "$HOME/.config" "$HOME/.config/systemd"; install -d -m 0755 "$udir"
if [[ -e "$udir/$UNIT" ]] && ! cmp -s "$src" "$udir/$UNIT"; then mv -T "$udir/$UNIT" "$(trash_dir)/$UNIT"; fi
if [[ ! -e "$udir/$UNIT" ]]; then install -m 0644 "$src" "$udir/$UNIT"; say "installed $udir/$UNIT"; fi
systemctl --user daemon-reload
systemctl --user enable -q "$UNIT"

# 6 -------------------------------------------------------------- shim
shim="$HOME/bin/filler-admin" want="$ROOT/current/app/scripts/filler-admin.sh"
install -d -m 0700 "$HOME/bin"
if [[ "$(readlink "$shim" 2>/dev/null)" != "$want" ]]; then
  if [[ -e "$shim" || -L "$shim" ]]; then mv -T "$shim" "$(trash_dir)/bin-filler-admin"; fi
  ln -s "$want" "$shim"
  say "$shim -> $want"
fi

# 7 -------------------------------------------------------------- restart
if [[ "${FILLER_NO_RESTART:-0}" == 1 ]]; then say "done (not restarted: filler-admin restart switches the running filler)"; exit 0; fi
systemctl --user restart "$UNIT"
for _ in $(seq 1 40); do
  if out="$(curl -fs --max-time 2 "$FILLER_URL/healthz" 2>/dev/null)"; then say "healthz: $out"; say "done: releases/$sha is running"; exit 0; fi
  sleep 0.5
done
journalctl --user -u "$UNIT" -n 30 --no-pager >&2 || true
die "healthz unreachable after 20 s; the unit runs releases/$sha${prev:+ (the previous release was $prev)}"
