#!/usr/bin/env bash
# Turn Vaultwarden's admin panel on or off (make vault-admin-on /
# vault-admin-off). No sudo: the env file lives in the vaultwarden-config
# volume of the standalone vaultwarden container (scripts/vaultwarden.sh), and
# is changed by a one-shot container running as Vaultwarden's uid, with no
# network and no capabilities.
#
#   vault-admin.sh on    asks for a new admin password on the terminal (twice),
#                        stores only its Argon2id PHC hash as ADMIN_TOKEN, and
#                        restarts the container. Then open
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
IMAGE="$(bash "$HERE/scripts/vaultwarden.sh" image)"
CONFIG_VOL=vaultwarden-config
docker volume inspect "$CONFIG_VOL" >/dev/null 2>&1 || { echo "vault-admin: no $CONFIG_VOL volume; make vault-up creates it" >&2; exit 1; }

# Inside: /config is the volume; MODE on|off. The new file is written next to
# the old one and renamed over it.
# shellcheck disable=SC2016  # expands inside the container, not here
EDIT_SH='
  set -eu
  umask 077
  env=/config/vaultwarden.env
  [ -f "$env" ] || { echo "vault-admin: vaultwarden.env missing; make vault-up VAULT_OWNER_EMAIL=<your vault email> writes it" >&2; exit 1; }
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
  -v "$CONFIG_VOL":/config -e MODE="$MODE" --entrypoint sh "$IMAGE" -c "$EDIT_SH"

# Vaultwarden reads ENV_FILE at start: restart it.
bash "$HERE/scripts/vaultwarden.sh" restart
