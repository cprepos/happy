#!/bin/sh
# Run by browser-init.sh in a one-shot container (root with only CHOWN, DAC_OVERRIDE and FOWNER,
# no network, read-only root), with HAPPY_BROWSER_HOME at /h. Sets the owners and modes each
# service's own uid needs, and copies each service's secret files into its own directory:
#
#   data/                          controller (CONTROLLER_UID) 0700, everything in it the same,
#   data/{,pods/slot-*/}browser-profile, downloads
#                                  controller:node 0775, their files the node's (BROWSER_NODE_UID)
#   bridge/                        bridge (BRIDGE_UID) 0700, its files the same
#   run/                           controller:LAUNCHER_SOCKET_GID 0750 (the launcher's socket)
#   run-docker/                    docker-proxy (DOCKER_PROXY_UID) 0750 (the proxy's socket)
#   secrets-bridge/                bridge 0500: api-token, vnc-password, bridge-token,
#                                  filler-client-token (when there is one), each 0400
#   secrets-launcher/              controller 0500: api-token, auth-state-key, share-token-secret, 0400
#
# secrets/ itself (the host's, read by the operator's tools) is only read. Only owners and modes
# that differ are changed, so a second run changes nothing.
set -eu -o pipefail

: "${CONTROLLER_UID:?}" "${BROWSER_NODE_UID:?}" "${BRIDGE_UID:?}" "${DOCKER_PROXY_UID:?}" "${LAUNCHER_SOCKET_GID:?}"
for v in "$CONTROLLER_UID" "$BROWSER_NODE_UID" "$BRIDGE_UID" "$DOCKER_PROXY_UID" "$LAUNCHER_SOCKET_GID"; do
  case "$v" in '' | *[!0-9]* | 0) echo "browser-perms: uids must be numbers other than 0" >&2; exit 1 ;; esac
done
C="$CONTROLLER_UID" N="$BROWSER_NODE_UID" B="$BRIDGE_UID" P="$DOCKER_PROXY_UID" S="$LAUNCHER_SOCKET_GID"
H=/h
cd "$H"

# own <uid:gid> <mode> <dir>: a directory's owner and mode, set only when they differ.
own() {
  [ "$(stat -c %u:%g "$3")" = "$1" ] || chown -h "$1" "$3"
  [ "$(stat -c %a "$3")" = "$2" ] || chmod "$2" "$3"
}

mkdir -p data data/pods data/chats data/browser-profile data/downloads bridge run run-docker secrets-bridge secrets-launcher

# data/: the controller's, except the node's two directories (shared stack and every slot).
n=$(find data \( -path data/browser-profile -o -path data/downloads -o -path 'data/pods/slot-*/browser-profile' \
  -o -path 'data/pods/slot-*/downloads' \) -prune -o \( ! -user "$C" -o ! -group "$C" \) -print -exec chown -h "$C:$C" {} + | wc -l)
for d in data data/pods data/chats; do own "$C:$C" 700 "$d"; done
for d in data/browser-profile data/downloads data/pods/slot-*/browser-profile data/pods/slot-*/downloads; do
  [ -d "$d" ] || continue
  own "$C:$N" 775 "$d"
  n=$((n + $(find "$d" -mindepth 1 \( ! -user "$N" -o ! -group "$N" \) -print -exec chown -h "$N:$N" {} + | wc -l)))
done

# bridge/: the bridge's stores.
n=$((n + $(find bridge -mindepth 1 \( ! -user "$B" -o ! -group "$B" \) -print -exec chown -h "$B:$B" {} + | wc -l)))
own "$B:$B" 700 bridge

own "$C:$S" 750 run
own "$P:$P" 750 run-docker

# copy <uid> <dir> <name>...: each secret file into dir, owned by uid, 0400, replaced atomically.
copy() {
  u="$1" dir="$2"; shift 2
  own "$u:$u" 700 "$dir"
  for f in "$@"; do
    [ -s "secrets/$f" ] || continue
    if [ -f "$dir/$f" ] && cmp -s "secrets/$f" "$dir/$f" && [ "$(stat -c %u:%a "$dir/$f")" = "$u:400" ]; then continue; fi
    cp "secrets/$f" "$dir/.$f.tmp"
    chown "$u:$u" "$dir/.$f.tmp"
    chmod 0400 "$dir/.$f.tmp"
    mv -f "$dir/.$f.tmp" "$dir/$f"
    n=$((n + 1))
  done
  chmod 0500 "$dir"
}
copy "$B" secrets-bridge api-token vnc-password bridge-token filler-client-token
copy "$C" secrets-launcher api-token auth-state-key share-token-secret

echo "browser-perms: $n owner or secret change(s)"
