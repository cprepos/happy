#!/usr/bin/env bash
# Turn Vaultwarden's admin panel on or off (make vault-admin-on /
# vault-admin-off). No sudo: the env file lives in the happy-vault-config
# volume, and is changed by a one-shot container running as Vaultwarden's
# uid, with no network and no capabilities.
#
#   vault-admin.sh on    asks for a new admin password on the terminal (twice),
#                        stores only its Argon2id PHC hash as ADMIN_TOKEN, and
#                        recreates the container. Then open
#                        http://127.0.0.1:8222/admin on this machine.
#   vault-admin.sh off   removes ADMIN_TOKEN, which disables /admin entirely.
#
# The password is read by `vaultwarden hash` from the TTY inside that
# container, and the hash goes from there straight into the env file on the
# volume; neither passes through this script, and neither is printed. The env
# file is copied to env-backups/ in the same volume before each change.
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "vault-admin: run as your own account, not root (no sudo needed)" >&2; exit 1; }
MODE="${1:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VUID="${VAULT_UID:-1991}"
IMAGE="$(awk '/^ *image: vaultwarden\/server:/{print $2; exit}' "$HERE/compose.vault.yml")"
docker volume inspect happy-vault-config >/dev/null 2>&1 || { echo "vault-admin: no happy-vault-config volume; run make vault-init first" >&2; exit 1; }

# Inside: /config is the volume; MODE on|off. The new file is written next to
# the old one and renamed over it.
# shellcheck disable=SC2016  # expands inside the container, not here
EDIT_SH='
  set -eu
  umask 077
  env=/config/vaultwarden.env
  [ -f "$env" ] || { echo "vault-admin: vaultwarden.env missing; run make vault-init first" >&2; exit 1; }
  if [ "$MODE" = on ]; then
    echo "Choose the admin panel password (typed twice, not shown)."
    # rpassword prompts on /dev/tty; only the result line goes to stdout -> /tmp (tmpfs).
    /vaultwarden hash >/tmp/hash.txt
    phc="$(grep -o "\$argon2id\$[^'"'"' ]*" /tmp/hash.txt | head -n1 || true)"
    [ -n "$phc" ] || { echo "vault-admin on: no hash produced (passwords did not match?)" >&2; exit 1; }
  elif ! grep -q "^ADMIN_TOKEN=" "$env"; then
    echo "vault-admin: ADMIN_TOKEN was not set; /admin already disabled."; exit 0
  fi
  mkdir -p /config/env-backups
  cp "$env" "/config/env-backups/vaultwarden.env.$(date -u +%Y%m%dT%H%M%SZ)"
  { grep -v "^ADMIN_TOKEN=" "$env" || true; [ "$MODE" = on ] && printf "ADMIN_TOKEN='"'"'%s'"'"'\n" "$phc"; true; } >"$env.tmp"
  mv "$env.tmp" "$env"
  if [ "$MODE" = on ]; then
    echo "vault-admin: ADMIN_TOKEN set (hash only). Admin panel: http://127.0.0.1:8222/admin (this machine only)."
  else
    echo "vault-admin: ADMIN_TOKEN removed; /admin is disabled."
  fi'

case "$MODE" in
  on) [[ -t 0 ]] || { echo "vault-admin on: needs an interactive terminal" >&2; exit 1; }; tty=(-it) ;;
  off) tty=() ;;
  *) echo "usage: vault-admin.sh on|off" >&2; exit 2 ;;
esac
docker run --rm "${tty[@]}" --network none --read-only --tmpfs /tmp:mode=0700,uid="$VUID" \
  --cap-drop ALL --security-opt no-new-privileges:true -u "$VUID:$VUID" \
  -v happy-vault-config:/config -e MODE="$MODE" --entrypoint sh "$IMAGE" -c "$EDIT_SH"

# Vaultwarden reads ENV_FILE at start: recreate it (only it; the filler keeps running).
docker compose -p happy-vault -f "$HERE/compose.vault.yml" up -d --force-recreate --no-deps --wait vaultwarden
