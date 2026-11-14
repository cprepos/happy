#!/usr/bin/env bash
# Vaultwarden as one standalone container in prep's Docker: `vaultwarden`,
# outside every compose project, with the label happy.standalone=vaultwarden.
# Run through make (selfhost/vault.mk); no sudo.
#
#   vaultwarden.sh up       start it; create it first if there is none. A running
#                           container is left alone (a no-op). Refuses if a container
#                           named vaultwarden exists without the label.
#   vaultwarden.sh down     stop it (the container and its volumes stay)
#   vaultwarden.sh restart  restart it (Vaultwarden reads ENV_FILE at start)
#   vaultwarden.sh status   container, image, 127.0.0.1-only bind, /alive, env keys
#   vaultwarden.sh logs     follow its log
#   vaultwarden.sh image    print the pinned image
#
# Its data is in two named volumes (uid 1991, 0700), never under /home:
#   vaultwarden-data     /data: db.sqlite3, attachments, rsa_key*
#   vaultwarden-config   /etc/vaultwarden (read-only in the container):
#                        vaultwarden.env (0600; ORG_CREATION_USERS and, while the
#                        admin panel is on, ADMIN_TOKEN) and env-backups/
# On a fresh machine `up` creates both and the env file (VAULT_OWNER_EMAIL=<your
# vault email> is needed for that once). It never removes a container or volume.
#
# Settings: VAULT_DOMAIN (required to create), VAULT_UID (1991), from
# selfhost/vault/.env through make.
set -euo pipefail

NAME=vaultwarden
LABEL=happy.standalone=vaultwarden
# 1.37.5-alpine, pinned by its index digest (docker buildx imagetools inspect, 2026-11-04).
IMAGE=vaultwarden/server:1.37.5-alpine@sha256:bbe684a02d6b0db54256ff88eac9754f4519284a7b26314afc241fd7d0918191
DATA_VOL=vaultwarden-data
CONFIG_VOL=vaultwarden-config
PORT=8222
VUID="${VAULT_UID:-1991}"
URL="http://127.0.0.1:$PORT"

cmd="${1:-}"
die() { echo "vaultwarden${cmd:+ $cmd}: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run as your own account, not root (no sudo needed)"
[[ "$VUID" =~ ^[1-9][0-9]{2,5}$ ]] || die "bad VAULT_UID $VUID"

exists() { docker container inspect "$NAME" >/dev/null 2>&1; }
label() { docker container inspect -f '{{index .Config.Labels "happy.standalone"}}' "$NAME" 2>/dev/null; }
running() { [[ "$(docker container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" == true ]]; }
ours() {
  exists || return 0
  [[ "$(label)" == vaultwarden ]] \
    || die "a container named $NAME exists without the label $LABEL; it is not this one. Look at it first (docker inspect $NAME)"
}
wait_alive() {
  local i
  for i in $(seq 1 60); do curl -fs --max-time 2 -o /dev/null "$URL/alive" && { echo "vaultwarden: $URL/alive answers"; return 0; }; sleep 1; done
  docker logs --tail 30 "$NAME" >&2 || true
  die "$URL/alive did not answer within 60 s"
}

ONE_SHOT=(docker run --rm --network none --read-only --security-opt no-new-privileges:true --cap-drop ALL --entrypoint sh)

# The volumes and the env file, only where missing.
prepare() {
  local v
  for v in "$DATA_VOL" "$CONFIG_VOL"; do
    if ! docker volume inspect "$v" >/dev/null 2>&1; then
      docker volume create --label "$LABEL" "$v" >/dev/null
      echo "vaultwarden: created volume $v"
    fi
  done
  # A new volume's top directory is root's: hand it to the uid (a one-shot root
  # container with only CAP_CHOWN). One already handed over is left alone.
  "${ONE_SHOT[@]}" --user 0:0 --cap-add CHOWN -v "$DATA_VOL":/v/data -v "$CONFIG_VOL":/v/config -e VUID="$VUID" "$IMAGE" -c '
    set -eu
    for d in /v/data /v/config; do if [ "$(stat -c %u "$d")" = 0 ]; then chmod 0700 "$d"; chown "$VUID:$VUID" "$d"; fi; done'
  "${ONE_SHOT[@]}" --user "$VUID:$VUID" -v "$CONFIG_VOL":/config -e OWNER_EMAIL="${VAULT_OWNER_EMAIL:-}" -e VUID="$VUID" "$IMAGE" -c '
    set -eu
    umask 077
    mkdir -p /config/env-backups
    env=/config/vaultwarden.env
    [ -e "$env" ] && exit 0
    case "$OWNER_EMAIL" in *@*) ;; *) echo "vaultwarden up: a new install needs VAULT_OWNER_EMAIL=<the email of your own vault account>" >&2; exit 1 ;; esac
    {
      echo "# Read by Vaultwarden itself (ENV_FILE=/etc/vaultwarden/vaultwarden.env). uid $VUID, 0600."
      echo "# Only these users may create organizations."
      printf "ORG_CREATION_USERS=%s\n" "$OWNER_EMAIL"
    } >"$env.tmp"
    mv "$env.tmp" "$env"
    echo "vaultwarden: wrote vaultwarden.env in the config volume"'
}

create() {
  [[ "${VAULT_DOMAIN:-}" =~ ^[a-z0-9.-]+$ ]] || die "set VAULT_DOMAIN in selfhost/vault/.env"
  prepare
  docker run -d --name "$NAME" --restart unless-stopped \
    --label "$LABEL" \
    --user "$VUID:$VUID" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
    --ulimit core=0 -p "127.0.0.1:$PORT:$PORT" \
    --health-cmd "wget -q -O /dev/null http://127.0.0.1:$PORT/alive" --health-interval 15s \
    --health-timeout 5s --health-retries 8 --health-start-period 10s \
    -e ENV_FILE=/etc/vaultwarden/vaultwarden.env -e DOMAIN="https://$VAULT_DOMAIN" \
    -e ROCKET_PORT="$PORT" -e DATA_FOLDER=/data -e SIGNUPS_ALLOWED=false -e INVITATIONS_ALLOWED=true \
    -e PASSWORD_HINTS_ALLOWED=false -e SHOW_PASSWORD_HINT=false -e SENDS_ALLOWED=false \
    -e EMERGENCY_ACCESS_ALLOWED=false -e PUSH_ENABLED=false -e IP_HEADER=X-Real-IP \
    -e LOGIN_RATELIMIT_SECONDS=60 -e LOGIN_RATELIMIT_MAX_BURST=5 \
    -e ADMIN_RATELIMIT_SECONDS=300 -e ADMIN_RATELIMIT_MAX_BURST=3 -e LOG_LEVEL=warn \
    -v "$DATA_VOL":/data -v "$CONFIG_VOL":/etc/vaultwarden:ro \
    "$IMAGE" >/dev/null
  echo "vaultwarden: created container $NAME ($IMAGE)"
}

image_note() {
  local img; img="$(docker container inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null || true)"
  if [[ -n "$img" && "$img" != "$IMAGE" ]]; then
    echo "vaultwarden: note: the container runs $img, not the pinned $IMAGE." >&2
    echo "  To move to the pin (the old container is kept as the rollback):" >&2
    echo "  docker stop $NAME && docker rename $NAME $NAME-\$(date -u +%Y%m%dT%H%M%SZ) && make vault-up" >&2
  fi
}

case "$cmd" in
  up)
    ours
    if running; then echo "vaultwarden: already running"; image_note; exit 0; fi
    if exists; then docker start "$NAME" >/dev/null; echo "vaultwarden: started $NAME"; image_note
    else create; fi
    wait_alive ;;
  down)
    ours
    if exists; then docker stop "$NAME" >/dev/null; echo "vaultwarden: stopped (container and volumes kept; make vault-up starts it)"
    else echo "vaultwarden: no container $NAME"; fi ;;
  restart)
    ours; exists || die "no container $NAME; make vault-up creates it"
    docker restart "$NAME" >/dev/null; wait_alive ;;
  status)
    if ! exists; then echo "container : none (make vault-up)"; exit 0; fi
    printf "container : %s\n" "$(docker container inspect -f '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} since {{.State.StartedAt}}' "$NAME" | sed 's#^/##')"
    printf "label     : %s\n" "$( [[ "$(label)" == vaultwarden ]] && echo "$LABEL" || echo "MISSING ($LABEL)")"
    printf "image     : %s\n" "$(docker container inspect -f '{{.Config.Image}}' "$NAME")"
    image_note
    # Vaultwarden loads the env file into its own process (ENV_FILE), so docker
    # exec printenv never shows these; read key names from the mount.
    printf "env file  : "
    docker exec "$NAME" sh -c 'f=/etc/vaultwarden/vaultwarden.env; test -r $f || { echo "not readable in the container"; exit 0; }
      for k in ORG_CREATION_USERS ADMIN_TOKEN; do grep -qE "^$k=.+" $f && printf "%s set  " $k || printf "%s unset  " $k; done; echo' \
      2>/dev/null || echo "container not running" ;;
  logs) docker logs -f --tail 200 "$NAME" ;;
  image) echo "$IMAGE" ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
