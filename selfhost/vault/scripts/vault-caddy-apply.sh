#!/usr/bin/env bash
# Add the vault.girthbass.duckdns.org site (../caddy-vault.conf) to the running
# Caddy's Caddyfile, right after the happy.girthbass.duckdns.org block.
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
CADDYFILE="${CADDYFILE:-/home/prep/caddy/Caddyfile}"
CADDY="${CADDY:-caddy}"
BLOCK="$HERE/caddy-vault.conf"
SITE='vault.girthbass.duckdns.org'

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
trap 'rm -f "$new"' EXIT
# After the closing brace of the happy. site; at the end if there is none.
awk -v blockfile="$BLOCK" '
  function emit(  l) { print ""; while ((getline l < blockfile) > 0) print l; close(blockfile); done = 1 }
  { print }
  /^happy\.girthbass\.duckdns\.org *\{/ { inhappy = 1; next }
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
trap - EXIT
"$CADDY" reload --config "$CADDYFILE" --adapter caddyfile
echo "vault-caddy-apply: added $SITE (backup: Caddyfile.backup.$epoch and $trash); Caddy reloaded"
