#!/usr/bin/env bash
# One-time (idempotent) setup of /srv/happy-filler, run as root (make
# filler-init uses sudo). Prints no secrets.
#
#   /srv/happy-filler/                 root 0755
#   /srv/happy-filler/releases/        root 0755   make filler-install
#   /srv/happy-filler/secrets/         1990 0500   files 0400 (vault-*, controller-token, client-token.sha256,
#                                                  vault-client-token.sha256)
#   /srv/happy-filler/state/           1990 0700   taint.json (no values)
#   /srv/happy-filler/audit/           1990:<user group> 2750, files 0640
#   /srv/happy-filler/policy.json      root:1990 0640 (skeleton if missing)
#   /srv/happy-filler/policy-backups/  root 0700   copies before each make filler-policy-edit
#
# The bridge's copy of the client token goes to
# $HAPPY_BROWSER_HOME/secrets/filler-client-token (the invoking user, 0600);
# the filler keeps only its SHA-256. FILLER_ROTATE=1 makes a new one (the old
# one is moved to secrets/old-<ts>/, not deleted).
#
# The vault tools' token (selfhost/vault-mcp, the /v1/vault/* routes only) goes
# to $VAULT_MCP_HOME/secrets/vault-client-token (the invoking user, 0600), its
# SHA-256 to secrets/vault-client-token.sha256. It is a different token from
# the bridge's, and FILLER_ROTATE=1 makes a new one of each.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "filler-init: run as root (make filler-init uses sudo)" >&2; exit 1; }
USER_NAME="${SUDO_USER:?filler-init: run through sudo from your own account}"
USER_GROUP="$(id -gn "$USER_NAME")"
BROWSER_HOME="${HAPPY_BROWSER_HOME:?}"
BSECRETS="$BROWSER_HOME/secrets"
VAULT_MCP_HOME="${VAULT_MCP_HOME:?}"
VSECRETS="$VAULT_MCP_HOME/secrets"
ROOT=/srv/happy-filler
FUID=1990
TS="$(date -u +%Y%m%dT%H%M%SZ)"

[[ -f "$BSECRETS/api-token" ]] || { echo "filler-init: $BSECRETS/api-token missing; run make browser-init first" >&2; exit 1; }

install -d -o root -g root -m 0755 "$ROOT" "$ROOT/releases"
install -d -o root -g root -m 0700 "$ROOT/policy-backups"
install -d -o "$FUID" -g "$FUID" -m 0700 "$ROOT/state"
install -d -o "$FUID" -g "$USER_GROUP" -m 2750 "$ROOT/audit"
install -d -o "$FUID" -g "$FUID" -m 0700 "$ROOT/secrets"   # 0500 again at the end

put() { # put <name> <source file>: install as 1990 0400, moving a different old one aside
  local dst="$ROOT/secrets/$1"
  if [[ -e "$dst" ]] && ! cmp -s "$2" "$dst"; then
    install -d -o "$FUID" -g "$FUID" -m 0700 "$ROOT/secrets/old-$TS"; mv "$dst" "$ROOT/secrets/old-$TS/"
  fi
  if [[ ! -e "$dst" ]]; then install -o "$FUID" -g "$FUID" -m 0400 "$2" "$dst"; echo "filler-init: wrote secrets/$1"; fi
}

# Client token (bridge -> filler).
TOK="$BSECRETS/filler-client-token"
if [[ -e "$TOK" && "${FILLER_ROTATE:-0}" == 1 ]]; then
  install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0700 "$BSECRETS/old-$TS"; mv "$TOK" "$BSECRETS/old-$TS/"
fi
if [[ ! -s "$TOK" ]]; then
  ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$TOK.tmp" ); mv "$TOK.tmp" "$TOK"
  echo "filler-init: wrote $TOK"
fi
chown "$USER_NAME:$USER_GROUP" "$TOK"; chmod 0600 "$TOK"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
printf '%s' "$(tr -d '\n' <"$TOK")" | sha256sum | cut -d' ' -f1 >"$tmp"
put client-token.sha256 "$tmp"

# Vault tools token (vault-mcp -> filler /v1/vault/*).
install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0700 "$VAULT_MCP_HOME" "$VSECRETS"
VTOK="$VSECRETS/vault-client-token"
if [[ -e "$VTOK" && "${FILLER_ROTATE:-0}" == 1 ]]; then
  install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0700 "$VSECRETS/old-$TS"; mv "$VTOK" "$VSECRETS/old-$TS/"
fi
if [[ ! -s "$VTOK" ]] || cmp -s "$VTOK" "$TOK"; then
  [[ -e "$VTOK" ]] && { install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0700 "$VSECRETS/old-$TS"; mv "$VTOK" "$VSECRETS/old-$TS/"; }
  ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$VTOK.tmp" ); mv "$VTOK.tmp" "$VTOK"
  echo "filler-init: wrote $VTOK"
fi
chown "$USER_NAME:$USER_GROUP" "$VTOK"; chmod 0600 "$VTOK"
printf '%s' "$(tr -d '\n' <"$VTOK")" | sha256sum | cut -d' ' -f1 >"$tmp"
put vault-client-token.sha256 "$tmp"

# The filler's own copy of the controller token.
tr -d '\n' <"$BSECRETS/api-token" >"$tmp"; put controller-token "$tmp"

chmod 0500 "$ROOT/secrets"

POL="$ROOT/policy.json"
if [[ ! -e "$POL" ]]; then
  printf '{\n  "version": 1,\n  "clients": {},\n  "chats": {}\n}\n' >"$POL"
  echo "filler-init: wrote an empty $POL (fill it with make filler-policy-edit)"
fi
chown "root:$FUID" "$POL"; chmod 0640 "$POL"
echo "filler-init: $ROOT ready"
