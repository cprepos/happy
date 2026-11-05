#!/usr/bin/env bash
# Enroll the filler with the agent's vault account, interactively. Run as root
# (make filler-enroll uses sudo): opens secrets/ for writing, runs the
# installed release's enroll.mjs as uid 1990 in a one-shot container on the
# terminal, then closes secrets/ again. The master password is typed into
# that container only and is never written anywhere.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "filler-enroll: run as root" >&2; exit 1; }
[[ -t 0 ]] || { echo "filler-enroll: needs a terminal" >&2; exit 1; }
ROOT=/srv/happy-filler
[[ -f "$ROOT/current/app/enroll.mjs" ]] || { echo "filler-enroll: run make filler-install COMMIT=<sha> first" >&2; exit 1; }
IMAGE="$(awk '/^ *image: node:/{print $2; exit}' "$ROOT/current/compose.filler.yml")"
chmod 0700 "$ROOT/secrets"
trap 'chmod 0500 "$ROOT/secrets"' EXIT
docker run --rm -it --network host --user 1990:1990 --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --ulimit core=0 \
  -e FILLER_HOME=/filler -e VAULT_URL="${VAULT_URL:-http://127.0.0.1:8222}" \
  -v "$ROOT/current/app:/app:ro" -v "$ROOT/secrets:/filler/secrets" \
  "$IMAGE" node /app/enroll.mjs
