#!/usr/bin/env bash
# Deploy a reviewed commit of the filler to /srv/happy-filler/releases/<sha>
# and point /srv/happy-filler/current at it. Run as root (make filler-install
# COMMIT=<sha> uses sudo). The source tree in /home is writable by agents, so
# only a commit you name is deployed, read from git, never the working tree.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "filler-install: run as root" >&2; exit 1; }
REPO="${FILLER_REPO:?}"; COMMIT="${COMMIT:-}"
USER_NAME="${SUDO_USER:?filler-install: run through sudo from your own account}"
[[ -n "$COMMIT" ]] || { echo "filler-install: COMMIT=<sha> is required (the commit you reviewed)" >&2; exit 1; }
SHA="$(sudo -u "$USER_NAME" git -C "$REPO" rev-parse --verify "$COMMIT^{commit}")"
ROOT=/srv/happy-filler
[[ -d "$ROOT/releases" ]] || { echo "filler-install: run make filler-init first" >&2; exit 1; }
REL="$ROOT/releases/$SHA"
if [[ -e "$REL" ]]; then
  echo "filler-install: $SHA already installed"
else
  stage="$(mktemp -d "$ROOT/releases/.stage-XXXXXX")"
  sudo -u "$USER_NAME" git -C "$REPO" archive --format=tar "$SHA" selfhost/browser/filler | tar -x -C "$stage"
  [[ -f "$stage/selfhost/browser/filler/server.mjs" ]] || { echo "filler-install: $SHA has no filler" >&2; mv "$stage" "$ROOT/releases/.failed-$SHA"; exit 1; }
  mkdir -p "$stage/rel"
  mv "$stage/selfhost/browser/filler" "$stage/rel/app"
  cp "$stage/rel/app/compose.filler.yml" "$stage/rel/compose.filler.yml"
  printf '%s\n' "$SHA" >"$stage/rel/COMMIT"
  chown -R root:root "$stage/rel"; chmod -R a-w,a+rX "$stage/rel"
  mv "$stage/rel" "$REL"; rmdir "$stage/selfhost" 2>/dev/null || true; rmdir "$stage" 2>/dev/null || true
  echo "filler-install: installed $SHA"
fi
prev="$(readlink "$ROOT/current" 2>/dev/null || true)"
ln -sfn "releases/$SHA" "$ROOT/current.new"; mv -T "$ROOT/current.new" "$ROOT/current"
echo "filler-install: current -> releases/$SHA${prev:+ (was $prev)}; run make filler-up to restart"
