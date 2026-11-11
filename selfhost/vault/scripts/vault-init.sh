#!/usr/bin/env bash
# One-time setup of /srv/happy-vault and /srv/happy-filler, run as root (make
# vault-init calls it through sudo; paths and uids from selfhost/vault/.env).
# Idempotent: existing directories keep their contents and owners, an existing
# env file is never rewritten. Prints no secrets (there are none yet:
# ADMIN_TOKEN is added later by make vault-admin-on).
#
#   /srv/happy-vault/            root 0755
#   /srv/happy-vault/data/       1991:1991 0700  Vaultwarden DATA_FOLDER
#   /srv/happy-vault/backups/    1991:1991 0700  make vault-backup
#   /srv/happy-vault/env-backups root 0700       copies of the env file before an edit
#   /srv/happy-vault/vaultwarden.env  root:1991 0640
#
#   /srv/happy-filler/           1990 0755        the filler container's /filler
#     secrets/                   1990 0500        (files 0400)
#     state/ policy-backups/ trash/  1990 0700
#     audit/                     1990:<operator> 2750  (files 0640)
#     outbox/                    1990:<operator> 2770  client tokens for make vault-tokens
#     inbox/                     1990:<operator> 3730  the controller token from make vault-tokens
# The filler's policy.json is written by make vault-init's next step, inside
# the filler container.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "vault-init: run as root (make vault-init uses sudo)" >&2; exit 1; }
OWNER_EMAIL="${VAULT_OWNER_EMAIL:-}"
VAULT_UID="${VAULT_UID:-1991}"
ROOT="${VAULT_ROOT:-/srv/happy-vault}"
FROOT="${FILLER_ROOT:-/srv/happy-filler}"
FUID="${FILLER_UID:-1990}"
FGID="${FILLER_GID:-1990}"
OP="${SUDO_USER:?vault-init: run through sudo from your own account (make vault-init)}"
OP_GROUP="$(id -gn "$OP")"
for v in "$VAULT_UID" "$FUID" "$FGID"; do [[ "$v" =~ ^[1-9][0-9]{2,5}$ ]] || { echo "vault-init: bad uid $v" >&2; exit 1; }; done

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

# The filler's tree. Only made where missing: an existing one keeps its owners.
mk() { local o="$1" g="$2" m="$3"; shift 3; local d; for d in "$@"; do [[ -e "$d" ]] || install -d -o "$o" -g "$g" -m "$m" "$d"; done; }
mk "$FUID" "$FGID" 0755 "$FROOT"
mk "$FUID" "$FGID" 0500 "$FROOT/secrets"
mk "$FUID" "$FGID" 0700 "$FROOT/state" "$FROOT/policy-backups" "$FROOT/trash"
mk "$FUID" "$OP_GROUP" 2750 "$FROOT/audit"
mk "$FUID" "$OP_GROUP" 2770 "$FROOT/outbox"
mk "$FUID" "$OP_GROUP" 3730 "$FROOT/inbox"
[[ "$(stat -c %u "$FROOT/secrets")" == "$FUID" ]] || { echo "vault-init: $FROOT/secrets is not owned by uid $FUID; look before going on" >&2; exit 1; }
echo "vault-init: $FROOT ready (owned by uid $FUID; audit, outbox and inbox shared with group $OP_GROUP)"
