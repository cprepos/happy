#!/usr/bin/env bash
# Turn Vaultwarden's admin panel on or off. Run as root (make vault-admin-on /
# vault-admin-off call it through sudo), because the env file is root-owned.
#
#   vault-admin.sh on    asks for a new admin password on the terminal (twice),
#                        stores only its Argon2id PHC hash as ADMIN_TOKEN, and
#                        recreates the container. Then open
#                        http://127.0.0.1:8222/admin on this machine.
#   vault-admin.sh off   removes ADMIN_TOKEN, which disables /admin entirely.
#
# The password is read by `vaultwarden hash` from the TTY inside a one-shot
# container with no network; it never passes through this script. Neither the
# password nor the hash is printed.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "vault-admin: run as root (make vault-admin-on/off use sudo)" >&2; exit 1; }
MODE="${1:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${VAULT_ROOT:-/srv/happy-vault}"
ENV="$ROOT/vaultwarden.env"
IMAGE="$(awk '/^ *image: vaultwarden\/server:/{print $2; exit}' "$HERE/compose.vault.yml")"
[[ -f "$ENV" ]] || { echo "vault-admin: $ENV missing; run make vault-init first" >&2; exit 1; }

backup_env() {
  local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 0600 -o root -g root "$ENV" "$ROOT/env-backups/vaultwarden.env.$ts"
}

write_env_without_admin() { # extra-line...
  local tmp="$ENV.tmp"
  umask 077
  { grep -v '^ADMIN_TOKEN=' "$ENV" || true; for l in "$@"; do printf '%s\n' "$l"; done; } >"$tmp"
  chown root:1991 "$tmp"; chmod 0640 "$tmp"
  mv "$tmp" "$ENV"
}

case "$MODE" in
  on)
    [[ -t 0 ]] || { echo "vault-admin on: needs an interactive terminal" >&2; exit 1; }
    work="$(mktemp -d "$ROOT/.admin-hash.XXXXXX")"; chmod 700 "$work"
    trap 'rm -rf "$work"' EXIT
    echo "Choose the admin panel password (typed twice, not shown)."
    # rpassword prompts on /dev/tty; only the result line goes to stdout -> file.
    docker run --rm -it --network none -v "$work:/out" --entrypoint sh "$IMAGE" \
      -c '/vaultwarden hash > /out/hash.txt'
    phc="$(grep -o "\$argon2id\$[^' ]*" "$work/hash.txt" | head -n1 || true)"
    [[ -n "$phc" ]] || { echo "vault-admin on: no hash produced (passwords did not match?)" >&2; exit 1; }
    backup_env
    write_env_without_admin "ADMIN_TOKEN='$phc'"
    unset phc
    echo "vault-admin: ADMIN_TOKEN set (hash only). Admin panel: http://127.0.0.1:8222/admin (this machine only)."
    ;;
  off)
    if grep -q '^ADMIN_TOKEN=' "$ENV"; then
      backup_env
      write_env_without_admin
      echo "vault-admin: ADMIN_TOKEN removed; /admin is disabled."
    else
      echo "vault-admin: ADMIN_TOKEN was not set; /admin already disabled."
    fi
    ;;
  *) echo "usage: vault-admin.sh on|off" >&2; exit 2 ;;
esac

# The container reads ENV_FILE at start: recreate it.
docker compose -p happy-vault -f "$HERE/compose.vault.yml" up -d --force-recreate --wait
