#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted scripts run inside the containers
# Moves an install from the old root-made /srv trees into the named volumes.
# No sudo: the copies run in one-shot containers of the pinned Vaultwarden
# image as the service's own uid (1990 or 1991), no network, no capabilities,
# with /srv mounted read-only. /srv is never changed: it stays the rollback.
#
#   vault-migrate.sh filler        copy /srv/happy-filler into happy-filler
#       (all but the old unit's releases/, current and pipe-bin/), modes kept,
#       audit/, outbox/ and inbox/ regrouped from the operator's group to the
#       filler's. Refused once the volume holds anything but empty directories.
#       The old systemd unit keeps serving 6091 from /srv meanwhile.
#   vault-migrate.sh vaultwarden   stop Vaultwarden, copy /srv/happy-vault's
#       data/, backups/ and vaultwarden.env into happy-vault-data, -backups and
#       -config, and start it on the volumes. Refused once happy-vault-data
#       holds anything. env-backups/ (root-only) is not copied; it stays in /srv.
#   vault-migrate.sh filler-cutover   after the old unit is stopped: every file
#       of policy.json, state/, secrets/, audit/ and outbox/ that is newer in
#       /srv (or missing in the volume) is copied again; the volume's older
#       copy goes to trash/<ts>-cutover/ first.
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "vault-migrate: run as your own account, not root (no sudo needed)" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VROOT="${VAULT_ROOT:-/srv/happy-vault}"
FROOT="${FILLER_ROOT:-/srv/happy-filler}"
VUID="${VAULT_UID:-1991}"
FUID="${FILLER_UID:-1990}"
FGID="${FILLER_GID:-1990}"
IMAGE="$(awk '/^ *image: vaultwarden\/server:/{print $2; exit}' "$HERE/compose.vault.yml")"
COMPOSE=(docker compose -p happy-vault -f "$HERE/compose.vault.yml")
# Volumes go on paths the image does not have (/vd, not /data): Docker copies an
# image directory's owner and mode onto an empty volume mounted over it.
ONE_SHOT=(docker run --rm --network none --read-only --security-opt no-new-privileges:true --cap-drop ALL --entrypoint sh)

bash "$HERE/scripts/vault-init.sh" volumes

case "${1:-}" in
  filler)
    [[ -d "$FROOT/secrets" ]] || { echo "vault-migrate: no $FROOT/secrets; nothing to migrate" >&2; exit 1; }
    "${ONE_SHOT[@]}" -u "$FUID:$FGID" --mount "type=bind,src=$FROOT,dst=/src,readonly" -v happy-filler:/dst \
      -e FGID="$FGID" "$IMAGE" -c '
      set -eu -o pipefail
      for e in $(ls -A /dst); do
        if [ ! -d "/dst/$e" ] || [ -n "$(ls -A "/dst/$e")" ]; then
          echo "vault-migrate: happy-filler already holds $e; not copying again (make vault-filler-cutover brings newer files across)" >&2; exit 3
        fi
      done
      n=0
      for e in $(ls -A /src); do
        case "$e" in releases|current|pipe-bin) continue ;; esac
        if [ -d "/src/$e" ]; then
          # A directory vault-init already made (empty): fill it, then give it the source mode.
          mkdir -p "/dst/$e"; chmod u+rwx "/dst/$e"
          cp -a "/src/$e/." "/dst/$e/" 2>&1 | { grep -v "preserve ownership" >&2 || true; }
          chmod "$(stat -c %a "/src/$e")" "/dst/$e"
        else
          cp -a "/src/$e" "/dst/$e" 2>&1 | { grep -v "preserve ownership" >&2 || true; }
        fi
        n=$((n + 1))
      done
      # The operator group was the host account'"'"'s; in the volume it is the filler'"'"'s.
      for d in audit outbox inbox; do [ -d "/dst/$d" ] && chgrp -R "$FGID" "/dst/$d"; done
      [ -d /dst/audit ] && chmod 2750 /dst/audit; [ -d /dst/outbox ] && chmod 2770 /dst/outbox; [ -d /dst/inbox ] && chmod 3730 /dst/inbox
      echo "vault-migrate: copied $n entries of the filler tree into happy-filler"'
    ;;
  vaultwarden)
    [[ -d "$VROOT/data" ]] || { echo "vault-migrate: no $VROOT/data; nothing to migrate" >&2; exit 1; }
    "${ONE_SHOT[@]}" -u "$VUID:$VUID" -v happy-vault-data:/d "$IMAGE" -c '[ -z "$(ls -A /d)" ]' \
      || { echo "vault-migrate: happy-vault-data is not empty; already migrated?" >&2; exit 3; }
    echo "vault-migrate: stopping Vaultwarden for the copy"
    "${COMPOSE[@]}" stop vaultwarden
    "${ONE_SHOT[@]}" -u "$VUID:$VUID" --mount "type=bind,src=$VROOT,dst=/src,readonly" \
      -v happy-vault-data:/vd -v happy-vault-backups:/vb -v happy-vault-config:/vc "$IMAGE" -c '
      set -eu -o pipefail
      quiet() { grep -v "preserve ownership" >&2 || true; }
      cp -a /src/data/. /vd/ 2>&1 | quiet; chmod 0700 /vd
      if [ -d /src/backups ]; then cp -a /src/backups/. /vb/ 2>&1 | quiet; chmod 0700 /vb; fi
      if [ -e /vc/vaultwarden.env ]; then echo "vault-migrate: happy-vault-config already has vaultwarden.env; left as is"
      else umask 077; cp /src/vaultwarden.env /vc/vaultwarden.env.tmp; mv /vc/vaultwarden.env.tmp /vc/vaultwarden.env; fi
      mkdir -p -m 0700 /vc/env-backups
      echo "vault-migrate: data $(du -sh /vd | cut -f1), backups $(ls /vb | grep -c "\.tar\.gz$") tarballs, env file copied"'
    "${COMPOSE[@]}" up -d --no-deps --wait vaultwarden
    echo "vault-migrate: Vaultwarden runs on the volumes; $VROOT is unchanged (the rollback)"
    ;;
  filler-cutover)
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    "${ONE_SHOT[@]}" -u "$FUID:$FGID" --mount "type=bind,src=$FROOT,dst=/src,readonly" -v happy-filler:/dst \
      -e TS="$ts" "$IMAGE" -c '
      set -eu -o pipefail
      umask 077
      n=0
      chmod 0700 /dst/secrets
      trap "chmod 0500 /dst/secrets" EXIT
      cd /src
      for f in policy.json $(find state secrets audit outbox -type f 2>/dev/null); do
        [ -f "/src/$f" ] || continue
        if [ -e "/dst/$f" ] && [ -z "$(find "/src/$f" -prune -newer "/dst/$f")" ]; then continue; fi
        if [ -e "/dst/$f" ]; then
          mkdir -p "/dst/trash/$TS-cutover/$(dirname "$f")"; mv "/dst/$f" "/dst/trash/$TS-cutover/$f"
        fi
        mkdir -p "/dst/$(dirname "$f")"; cp -a "/src/$f" "/dst/$f" 2>&1 | { grep -v "preserve ownership" >&2 || true; }
        echo "vault-migrate: $f copied again (newer in /srv)"; n=$((n + 1))
      done
      chgrp -R "$(stat -c %g /dst/outbox)" /dst/outbox /dst/audit
      echo "vault-migrate: $n file(s) brought across"'
    ;;
  *) echo "usage: vault-migrate.sh filler|vaultwarden|filler-cutover" >&2; exit 2 ;;
esac
