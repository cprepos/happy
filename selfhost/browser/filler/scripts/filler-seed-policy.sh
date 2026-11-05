#!/usr/bin/env bash
# Seed /srv/happy-filler/policy.json for "every chat uses the agent's logins",
# run as root by make filler-setup. Only a policy that is still empty (missing,
# blank, or the skeleton filler-init writes) is replaced; anything else is left
# as it is. The old file is copied to policy-backups/ first. The seed:
#   {"version":1,"default_client":"agent","clients":{"agent":{"all_items":true,"secrets":{},
#     "manage":{"create":true,"update":true,"remove":true,"compare":true,"pipe":[]}}},"chats":{},"pipe_targets":{}}
# Every chat may then use every login in the agent account's vault, each only
# on the https hosts of its own saved URIs; a login added to the vault later
# needs no policy edit. manage lets the vault tools (selfhost/vault-mcp)
# create, change, trash and restore those logins and compare them against a
# hash; pipe_targets starts empty (add commands with make filler-policy-edit).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "filler-seed-policy: run as root" >&2; exit 1; }
ROOT=/srv/happy-filler
POL="$ROOT/policy.json"
CLIENT="${FILLER_DEFAULT_CLIENT:-agent}"
[[ "$CLIENT" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || { echo "filler-seed-policy: bad client name" >&2; exit 1; }
[[ -d "$ROOT/policy-backups" ]] || { echo "filler-seed-policy: run make filler-init first" >&2; exit 1; }

norm=""
[[ -e "$POL" ]] && norm="$(tr -d ' \t\r\n' <"$POL")"
if [[ -n "$norm" && "$norm" != '{"version":1,"clients":{},"chats":{}}' ]]; then
  echo "filler-seed-policy: $POL already has content; left as is"
  exit 0
fi
if [[ -e "$POL" ]]; then cp -p "$POL" "$ROOT/policy-backups/policy.$(date -u +%Y%m%dT%H%M%SZ).json"; fi
tmp="$(mktemp "$ROOT/.policy.XXXXXX")"
printf '{"version":1,"default_client":"%s","clients":{"%s":{"all_items":true,"secrets":{},"manage":{"create":true,"update":true,"remove":true,"compare":true,"pipe":[]}}},"chats":{},"pipe_targets":{}}\n' "$CLIENT" "$CLIENT" >"$tmp"
chown "root:1990" "$tmp"; chmod 0640 "$tmp"
mv -f "$tmp" "$POL"
echo "filler-seed-policy: wrote $POL: default_client \"$CLIENT\" with all_items (every vault login, on its own URIs' hosts) and manage"
if [[ -f "$ROOT/current/app/server.mjs" ]]; then
  IMAGE="$(awk '/^ *image: node:/{print $2; exit}' "$ROOT/current/compose.filler.yml")"
  docker run --rm --network none --user 1990:1990 --read-only --cap-drop ALL \
    -v "$ROOT/current/app:/app:ro" -v "$POL:/filler/policy.json:ro" \
    "$IMAGE" node /app/server.mjs --check-policy /filler/policy.json
fi
