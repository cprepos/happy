#!/usr/bin/env bash
# One-time setup of the vault's named volumes, run as the operator (make
# vault-init; uids from selfhost/vault/.env). No sudo: everything below runs
# in one-shot containers of the pinned Vaultwarden image, with no network and
# no capabilities, except the first step, which runs as root with only
# CAP_CHOWN to hand a new, empty volume's top directory to its uid.
# Idempotent: existing volumes, directories and the env file are left as they
# are. `vault-init.sh volumes` stops after creating the volumes. Prints no
# secrets (there are none yet: ADMIN_TOKEN is added later by make
# vault-admin-on).
#
#   happy-vault-data/      1991 0700  Vaultwarden DATA_FOLDER
#   happy-vault-backups/   1991 0700  make vault-backup
#   happy-vault-config/    1991 0700
#     vaultwarden.env      1991 0600  ORG_CREATION_USERS (ADMIN_TOKEN later)
#     env-backups/         1991 0700  copies of the env file before an edit
#
#   happy-filler/          1990 0700  the filler container's /filler
#     secrets/             1990 0500  (files 0400)
#     state/ policy-backups/ trash/  1990 0700
#     audit/               1990:1990 2750  (files 0640; the operator container reads them)
#     outbox/              1990:1990 2770  client tokens for make vault-tokens
#     inbox/               1990:1990 3730  the controller token from make vault-tokens
# The filler's policy.json is written by make vault-init's next step, inside
# the filler container.
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "vault-init: run as your own account, not root (no sudo needed)" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OWNER_EMAIL="${VAULT_OWNER_EMAIL:-}"
VUID="${VAULT_UID:-1991}"
FUID="${FILLER_UID:-1990}"
FGID="${FILLER_GID:-1990}"
for v in "$VUID" "$FUID" "$FGID"; do [[ "$v" =~ ^[1-9][0-9]{2,5}$ ]] || { echo "vault-init: bad uid $v" >&2; exit 1; }; done
IMAGE="$(awk '/^ *image: vaultwarden\/server:/{print $2; exit}' "$HERE/compose.vault.yml")"
ONE_SHOT=(docker run --rm --network none --read-only --security-opt no-new-privileges:true --cap-drop ALL --entrypoint sh)

for vol in happy-vault-data happy-vault-backups happy-vault-config happy-filler; do
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    docker volume create --label org.happy.vault=1 "$vol" >/dev/null
    echo "vault-init: created volume $vol"
  fi
done

# A new volume's top directory is root's: chmod (as its owner) then chown to
# the service uid. One already handed over (not root's) is left alone.
"${ONE_SHOT[@]}" --user 0:0 --cap-add CHOWN \
  -v happy-vault-data:/v/data -v happy-vault-backups:/v/backups -v happy-vault-config:/v/config -v happy-filler:/v/filler \
  -e VUID="$VUID" -e FUID="$FUID" -e FGID="$FGID" "$IMAGE" -c '
    set -eu
    own() { if [ "$(stat -c %u "$1")" = 0 ]; then chmod 0700 "$1"; chown "$2" "$1"; fi; }
    own /v/data "$VUID:$VUID"; own /v/backups "$VUID:$VUID"; own /v/config "$VUID:$VUID"; own /v/filler "$FUID:$FGID"'
# vault-init.sh volumes: only the above (make vault-migrate-volumes fills them from /srv).
[[ "${1:-}" != volumes ]] || exit 0

"${ONE_SHOT[@]}" --user "$VUID:$VUID" -v happy-vault-config:/config -e OWNER_EMAIL="$OWNER_EMAIL" -e VUID="$VUID" "$IMAGE" -c '
    set -eu
    umask 077
    mkdir -p /config/env-backups
    env=/config/vaultwarden.env
    if [ -e "$env" ]; then echo "vault-init: vaultwarden.env already present, left as is"; exit 0; fi
    case "$OWNER_EMAIL" in *@*) ;; *) echo "vault-init: set VAULT_OWNER_EMAIL=<the email of your own vault account>" >&2; exit 1 ;; esac
    {
      echo "# Read by Vaultwarden itself (ENV_FILE=/etc/vaultwarden/vaultwarden.env). uid $VUID, 0600."
      echo "# Only these users may create organizations."
      printf "ORG_CREATION_USERS=%s\n" "$OWNER_EMAIL"
    } >"$env.tmp"
    mv "$env.tmp" "$env"
    echo "vault-init: wrote vaultwarden.env in happy-vault-config"'
echo "vault-init: Vaultwarden volumes ready (uid $VUID)"

# The filler's tree. Only made where missing: an existing one keeps its modes.
"${ONE_SHOT[@]}" --user "$FUID:$FGID" -v happy-filler:/filler "$IMAGE" -c '
    set -eu
    mk() { m="$1"; shift; for d in "$@"; do [ -e "/filler/$d" ] || { mkdir "/filler/$d"; chmod "$m" "/filler/$d"; }; done; }
    mk 0500 secrets
    mk 0700 state policy-backups trash
    mk 2750 audit
    mk 2770 outbox
    mk 3730 inbox'
echo "vault-init: happy-filler ready (uid $FUID; audit, outbox and inbox shared with the operator container through group $FGID)"
