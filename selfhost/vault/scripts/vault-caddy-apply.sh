#!/usr/bin/env bash
# Add the $VAULT_DOMAIN site (the template ../caddy-vault.conf) to the running
# Caddy's Caddyfile, right after the $CADDY_AFTER_SITE block. Both, and
# CADDYFILE, come from selfhost/vault/.env through make vault-caddy-apply.
# Idempotent: a Caddyfile that already has the site is left alone.
#
# Before the edit the current file is copied twice: Caddyfile.backup.<epoch>
# beside it (the existing convention there) and into the repo's
# trash/<ts>_caddyfile-vault/. The new file is validated with caddy validate
# before it replaces the old one, then Caddy is reloaded. Nothing in the
# Caddyfile is printed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CADDYFILE="${CADDYFILE:?set CADDYFILE in selfhost/vault/.env}"
CADDY="${CADDY:-caddy}"
SITE="${VAULT_DOMAIN:?set VAULT_DOMAIN in selfhost/vault/.env}"
AFTER="${CADDY_AFTER_SITE:-}"
[[ "$SITE" =~ ^[a-z0-9.-]+$ && ( -z "$AFTER" || "$AFTER" =~ ^[a-z0-9.-]+$ ) ]] || { echo "vault-caddy-apply: bad VAULT_DOMAIN or CADDY_AFTER_SITE" >&2; exit 1; }

[[ -f "$CADDYFILE" ]] || { echo "vault-caddy-apply: no $CADDYFILE" >&2; exit 1; }
if grep -qE "^${SITE//./\\.} *\{" "$CADDYFILE"; then
  echo "vault-caddy-apply: $SITE already in $CADDYFILE; nothing to do"
  exit 0
fi

dir="$(dirname "$CADDYFILE")"
epoch="$(date +%s)"
ts="$(date +%Y%m%d_%H%M%S)"
cp -p "$CADDYFILE" "$dir/Caddyfile.backup.$epoch"
trash="$REPO/trash/${ts}_caddyfile-vault"
mkdir -p "$trash"; chmod 700 "$trash"
cp -p "$CADDYFILE" "$trash/Caddyfile"
printf 'Caddyfile before make vault-caddy-apply added the %s site.\n' "$SITE" >"$trash/README.txt"

new="$(mktemp "$dir/.Caddyfile.vault.XXXXXX")"
BLOCK="$(mktemp "$dir/.caddy-vault.conf.XXXXXX")"
trap 'rm -f "$new" "$BLOCK"' EXIT
sed "s/@VAULT_DOMAIN@/$SITE/g" "$HERE/caddy-vault.conf" >"$BLOCK"
# After the closing brace of the happy. site; at the end if there is none.
awk -v blockfile="$BLOCK" -v after="$AFTER" '
  function emit(  l) { print ""; while ((getline l < blockfile) > 0) print l; close(blockfile); done = 1 }
  { print }
  after != "" && index($0, after) == 1 && substr($0, length(after) + 1) ~ /^ *\{/ { inhappy = 1; next }
  inhappy && /^\}/ { inhappy = 0; if (!done) emit() }
  END { if (!done) emit() }
' "$CADDYFILE" >"$new"
chmod --reference="$CADDYFILE" "$new"

"$CADDY" validate --config "$new" --adapter caddyfile >/dev/null 2>"$new.err" || {
  echo "vault-caddy-apply: caddy validate failed; Caddyfile unchanged:" >&2
  grep -viE 'bearer|authorization|token|password|hash' "$new.err" | tail -n 5 >&2
  rm -f "$new.err"; exit 1; }
rm -f "$new.err"
mv "$new" "$CADDYFILE"
rm -f "$BLOCK"
trap - EXIT
"$CADDY" reload --config "$CADDYFILE" --adapter caddyfile
echo "vault-caddy-apply: added $SITE (backup: Caddyfile.backup.$epoch and $trash); Caddy reloaded"
