#!/bin/sh
# Run by browser-init.sh in a one-shot container (root with only CHOWN, DAC_OVERRIDE and FOWNER,
# no network, read-only root), with HAPPY_BROWSER_HOME at /h. Sets the owners and modes each
# service's own uid needs, and copies each service's secret files into its own directory:
#
#   data/                          controller (CONTROLLER_UID) 0700, everything in it the same,
#   data/pods/.quarantine/         controller 0700, everything in it the controller's too: slot trees
#                                  the launcher could not wipe (someone else's files in them) and
#                                  renamed aside; after this run make browser-pods-reap QUARANTINE=1
#                                  can move them out
#   data/{,pods/slot-*/}browser-profile, downloads
#                                  controller:node 0770, their files the node's (BROWSER_NODE_UID)
#   ACL entries for the host agent (HOST_AGENT_UID, prep), which uses its chats' downloads and
#   staged uploads straight on the host (the launcher sets the same on every fresh slot, the
#   controller patch on each session's artifacts/<sid>/downloads):
#     data, data/pods, data/pods/slot-*, {data,slot-*}/artifacts, {data,slot-*}/artifacts/*
#                                  u:A:--x, traverse only: never a listing or a read of the rest
#     {data,slot-*}/uploads, {data,slot-*}/downloads, {data,slot-*}/artifacts/*/downloads
#                                  u:A:rwX on them and all they hold, and default entries (rwx for
#                                  A, the controller and on downloads the node; mask rwx; nothing
#                                  for other) so what lands there later is the same
#   Nothing in data is left to "other" where A can reach it: the entries right under data, data/pods
#   and each slot lose their "other" bits, so browser-profile, auth, chats, .quarantine and the
#   controller's own directories stay shut to A. The known limit: entries are per uid, not per chat.
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

: "${CONTROLLER_UID:?}" "${BROWSER_NODE_UID:?}" "${BRIDGE_UID:?}" "${DOCKER_PROXY_UID:?}" "${LAUNCHER_SOCKET_GID:?}" "${HOST_AGENT_UID:?}"
for v in "$CONTROLLER_UID" "$BROWSER_NODE_UID" "$BRIDGE_UID" "$DOCKER_PROXY_UID" "$LAUNCHER_SOCKET_GID" "$HOST_AGENT_UID"; do
  case "$v" in '' | *[!0-9]* | 0) echo "browser-perms: uids must be numbers other than 0" >&2; exit 1 ;; esac
done
for v in "$CONTROLLER_UID" "$BROWSER_NODE_UID" "$BRIDGE_UID" "$DOCKER_PROXY_UID"; do
  [ "$v" != "$HOST_AGENT_UID" ] || { echo "browser-perms: HOST_AGENT_UID must not be a service's uid" >&2; exit 1; }
done
command -v setfacl >/dev/null && command -v getfacl >/dev/null || { echo "browser-perms: needs setfacl (the acl-tools image)" >&2; exit 1; }
C="$CONTROLLER_UID" N="$BROWSER_NODE_UID" B="$BRIDGE_UID" P="$DOCKER_PROXY_UID" S="$LAUNCHER_SOCKET_GID" A="$HOST_AGENT_UID"
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
# data and data/pods show 0710: their group bits are the ACL mask, --x for the host agent's entry.
for d in data data/pods; do own "$C:$C" 710 "$d"; done
own "$C:$C" 700 data/chats
# The find above already gave the quarantine's contents to the controller (its slot trees are not
# pruned: their path is not data/pods/slot-*); the directory itself is the controller's alone.
[ -d data/pods/.quarantine ] && own "$C:$C" 700 data/pods/.quarantine
for d in data/browser-profile data/downloads data/pods/slot-*/browser-profile data/pods/slot-*/downloads; do
  [ -d "$d" ] || continue
  own "$C:$N" 770 "$d"
  n=$((n + $(find "$d" -mindepth 1 \( ! -user "$N" -o ! -group "$N" \) -print -exec chown -h "$N:$N" {} + | wc -l)))
done

# The host agent's ACL entries (the header). acl <-R|-> <spec> <path>: set only when getfacl
# shows a change, so a second run counts none.
acl() {
  [ -e "$3" ] && [ ! -L "$3" ] || return 0
  if [ "$1" = -R ]; then before=$(getfacl -Rcpn "$3"); setfacl -R -m "$2" "$3"; after=$(getfacl -Rcpn "$3")
  else before=$(getfacl -cpn "$3"); setfacl -m "$2" "$3"; after=$(getfacl -cpn "$3"); fi
  [ "$before" = "$after" ] || n=$((n + 1))
}
for s in data data/pods/slot-*; do
  [ -d "$s" ] || continue
  for d in "$s/uploads" "$s/artifacts"; do
    [ -d "$d" ] || { mkdir "$d"; chmod 770 "$d"; }
    [ "$(stat -c %u:%g "$d")" = "$C:$C" ] || chown -h "$C:$C" "$d"
  done
done
# Traverse only, and nothing right under each for "other" (A gets in here; nothing else should).
for p in data data/pods data/pods/slot-* data/artifacts data/artifacts/* data/pods/slot-*/artifacts data/pods/slot-*/artifacts/*; do
  [ -d "$p" ] && [ ! -L "$p" ] || continue
  n=$((n + $(find "$p" -mindepth 1 -maxdepth 1 ! -type l -perm /o=rwx -print -exec chmod o-rwx {} + | wc -l)))
  acl - "u:$A:--x" "$p"
done
share="d:u::rwx,d:u:$A:rwx,d:u:$C:rwx,d:g::rwx,d:m::rwx,d:o::---"
for s in data data/pods/slot-*; do
  [ -d "$s" ] || continue
  for a in "$s"/artifacts/*/downloads; do
    [ -d "$a" ] && [ ! -L "$a" ] && [ ! -L "${a%/downloads}" ] || continue
    acl -R "u:$A:rwX,u:$C:rwX,o::---,$share" "$a"
  done
  acl -R "u:$A:rwX,o::---,$share" "$s/uploads"
  acl -R "u:$A:rwX,u:$N:rwX,o::---,$share,d:u:$N:rwx" "$s/downloads"
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

echo "browser-perms: $n owner, mode, ACL or secret change(s)"
