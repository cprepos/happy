#!/usr/bin/env bash
# One-time setup of /srv/happy-vault, run as root (make vault-init calls it
# through sudo). Idempotent: existing directories keep their contents, an
# existing env file is never rewritten. Prints no secrets (there are none yet:
# ADMIN_TOKEN is added later by make vault-admin-on).
#
#   /srv/happy-vault/            root 0755
#   /srv/happy-vault/data/       1991:1991 0700  Vaultwarden DATA_FOLDER
#   /srv/happy-vault/backups/    1991:1991 0700  make vault-backup
#   /srv/happy-vault/env-backups root 0700       copies of the env file before an edit
#   /srv/happy-vault/vaultwarden.env  root:1991 0640
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "vault-init: run as root (make vault-init uses sudo)" >&2; exit 1; }
OWNER_EMAIL="${VAULT_OWNER_EMAIL:-}"
VAULT_UID=1991
ROOT=/srv/happy-vault

install -d -o root -g root -m 0755 "$ROOT"
install -d -o "$VAULT_UID" -g "$VAULT_UID" -m 0700 "$ROOT/data" "$ROOT/backups"
install -d -o root -g root -m 0700 "$ROOT/env-backups"

ENV="$ROOT/vaultwarden.env"
if [[ ! -e "$ENV" ]]; then
  [[ "$OWNER_EMAIL" == *@* ]] || { echo "vault-init: set VAULT_OWNER_EMAIL=<the email of your own vault account>" >&2; exit 1; }
  umask 077
  {
    echo "# Read by Vaultwarden itself (ENV_FILE=/etc/vaultwarden.env). root:$VAULT_UID 0640."
    echo "# Only these users may create organizations."
    printf 'ORG_CREATION_USERS=%s\n' "$OWNER_EMAIL"
  } >"$ENV.tmp"
  mv "$ENV.tmp" "$ENV"
  echo "vault-init: wrote $ENV"
else
  echo "vault-init: $ENV already present, left as is"
fi
chown "root:$VAULT_UID" "$ENV"
chmod 0640 "$ENV"
echo "vault-init: $ROOT ready (data and backups owned by uid $VAULT_UID)"
