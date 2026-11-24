#!/usr/bin/env bash
# make browser-pods-reap QUARANTINE=1: move the launcher's quarantine (data/pods/.quarantine, slot
# trees it could not wipe and renamed aside; see wipe in launcher/launcher.mjs) out of the stack, into
# ~/trash/<UTC time>_browser-quarantine/, owned by the operator. Moved, never removed: what is in
# there is someone's staged files, and whoever looks next decides what to keep.
#
# data/ is the controller's (1993) 0700 and the trees in the quarantine can belong to anyone (that is
# why they are there), so the operator cannot reach them from the host. The move runs in the same
# kind of one-shot container as browser-perms.sh: root with only CHOWN, DAC_OVERRIDE and FOWNER, no
# network, a read-only root, HAPPY_BROWSER_HOME at /h and the new trash directory at /t. The two are
# separate mounts, so mv copies and then unlinks the source, as mv does across filesystems.
set -euo pipefail

: "${HAPPY_BROWSER_HOME:?run through browser-stack/browser.mk}"
TRASH_ROOT="${TRASH_ROOT:-$HOME/trash}"
DEST="$TRASH_ROOT/$(date -u +%Y%m%dT%H%M%SZ)_browser-quarantine"
mkdir -p "$DEST"
PERMS_IMAGE="node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914"
docker run --rm --network none --read-only --security-opt no-new-privileges:true -u 0:0 \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  -e OWNER="$(id -u):$(id -g)" -v "$HAPPY_BROWSER_HOME:/h" -v "$DEST:/t" --entrypoint sh "$PERMS_IMAGE" -euc '
    q=/h/data/pods/.quarantine
    n=0
    if [ -d "$q" ]; then
      for e in "$q"/* "$q"/.[!.]*; do
        [ -e "$e" ] || continue
        mv "$e" /t/
        echo "moved $(basename "$e")"
        n=$((n + 1))
      done
    fi
    chown -R "$OWNER" /t
    echo "quarantine-reap: $n entr$([ "$n" = 1 ] && echo y || echo ies) moved"
  '
if [ -z "$(ls -A "$DEST")" ]; then
  rmdir "$DEST"
  echo "quarantine-reap: the quarantine was empty; nothing moved"
else
  echo "quarantine-reap: in $DEST"
fi
