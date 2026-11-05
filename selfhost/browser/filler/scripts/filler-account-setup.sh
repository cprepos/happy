#!/usr/bin/env bash
# The one filler step that needs root, run once: create the secret filler's own
# account, happy-filler (uid/gid 1990, the owner its secrets and state already
# have), and hand /srv/happy-filler to it. Nothing else ever runs as root:
# installing a release, the user unit, starting the filler and every token
# handoff are done afterwards as happy-filler (su - happy-filler) or as prep,
# through make targets, with no sudo.
#
#   make filler-account-setup COMMIT=<sha>   (as prep; asks for your sudo
#                                            password, then happy-filler's new
#                                            password twice)
#
# The make target runs this script as it is in COMMIT (git cat-file), not the
# working tree. It does only this:
#
#   1 check the state             4 enable linger
#   2 record it (no secrets)      5 stop the old docker filler
#   3 the account + its password  6 chown /srv/happy-filler; make outbox/, inbox/
#
# Idempotent: a re-run finishes what an earlier run left. It never deletes,
# never reads or changes what is in secrets/ (those files already belong to
# uid 1990), never copies a token, and never installs or starts anything.
# FILLER_NEW_PASSWORD=1 asks for the password again on a re-run.
set -euo pipefail
die() { echo "filler-account-setup: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (make filler-account-setup COMMIT=<sha> runs it with sudo)"
[[ -t 0 ]] || die "needs a terminal (it asks for happy-filler's password)"
OP="${SUDO_USER:?filler-account-setup: run through sudo from your own account}"
[[ "$OP" != root ]] || die "run through sudo from your own account, not root's"
OP_GROUP="$(id -gn "$OP")"
ACCT=happy-filler FUID=1990 HOMED=/var/lib/happy-filler ROOT=/srv/happy-filler
CONTAINER=happy-filler-filler-1
RUNDIR=/run/user/$FUID
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BAD_GROUPS="sudo docker lxd adm admin wheel root"
REPO="${FILLER_REPO:-/home/$OP/happy}"

echo "== 1/6 state"
if u="$(getent passwd "$ACCT")"; then
  [[ "$(cut -d: -f3 <<<"$u")" == "$FUID" ]] || die "$ACCT exists with a uid other than $FUID"
  echo "account $ACCT: exists"
else
  ! getent passwd "$FUID" >/dev/null || die "uid $FUID belongs to $(getent passwd "$FUID" | cut -d: -f1), not $ACCT"
  echo "account $ACCT: to be created"
fi
if g="$(getent group "$ACCT")"; then
  [[ "$(cut -d: -f3 <<<"$g")" == "$FUID" ]] || die "group $ACCT exists with a gid other than $FUID"
else
  ! getent group "$FUID" >/dev/null || die "gid $FUID belongs to group $(getent group "$FUID" | cut -d: -f1), not $ACCT"
fi
if [[ -d "$ROOT/secrets" ]]; then
  [[ "$(stat -c %u "$ROOT/secrets")" == "$FUID" ]] || die "$ROOT/secrets is not owned by uid $FUID; look before going on"
fi
running=no
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then running="$(docker container inspect -f '{{.State.Status}}' "$CONTAINER")"; fi
echo "docker filler $CONTAINER: $running"
for f in client-token.sha256 vault-client-token.sha256 controller-token vault-user-key; do
  printf 'secrets/%s: %s\n' "$f" "$([[ -s "$ROOT/secrets/$f" ]] && echo present || echo absent)"
done

echo "== 2/6 record"
B="$ROOT/policy-backups/account-setup-$TS"
install -d -m 0755 "$ROOT"
install -d -m 0700 "$ROOT/policy-backups" "$B"
[[ -e "$ROOT/policy.json" ]] && cp -p "$ROOT/policy.json" "$B/policy.json"
[[ -e "$ROOT/current/compose.filler.yml" ]] && cp -p "$ROOT/current/compose.filler.yml" "$B/compose.filler.yml"
[[ "$running" != no ]] && docker container inspect "$CONTAINER" >"$B/container-inspect.json"
# Names, owners and modes only; never contents.
{ stat -c '%A %U:%G %n' "$ROOT" "$ROOT"/* "$ROOT"/releases/* 2>/dev/null || true; } >"$B/layout-before.txt"
echo "recorded in $B"

echo "== 3/6 account"
getent group "$ACCT" >/dev/null || groupadd -g "$FUID" "$ACCT"
if ! getent passwd "$ACCT" >/dev/null; then
  useradd -u "$FUID" -g "$FUID" -d "$HOMED" -m -s /bin/bash -c "Happy secret filler" "$ACCT"
  echo "created $ACCT (uid $FUID, home $HOMED)"
fi
install -d -o "$ACCT" -g "$ACCT" -m 0700 "$HOMED"
for grp in $(id -nG "$ACCT"); do
  for bad in $BAD_GROUPS; do
    [[ "$grp" != "$bad" ]] || die "$ACCT is in group $bad; take it out (gpasswd -d $ACCT $bad) and re-run"
  done
done
echo "groups of $ACCT: $(id -nG "$ACCT") (none of: $BAD_GROUPS)"
pwstate="$(passwd -S "$ACCT" | awk '{print $2}')"
if [[ "$pwstate" != P || "${FILLER_NEW_PASSWORD:-0}" == 1 ]]; then
  echo "Choose a password for $ACCT (you type it at su - $ACCT for every admin command):"
  tries=0
  until passwd "$ACCT"; do tries=$((tries + 1)); [[ $tries -lt 3 ]] || die "password not set; re-run to try again"; done
else
  echo "password: already set (FILLER_NEW_PASSWORD=1 to change it)"
fi

echo "== 4/6 linger"
loginctl enable-linger "$ACCT"
systemctl start "user@$FUID.service"
for _ in $(seq 1 40); do [[ -S "$RUNDIR/systemd/private" ]] && break; sleep 0.5; done
[[ -S "$RUNDIR/systemd/private" ]] || die "the user manager of $ACCT did not come up ($RUNDIR/systemd/private)"
echo "linger on; user@$FUID.service running"

echo "== 5/6 stop the docker filler"
# Before the chown: the docker filler wants a root-owned policy.json. It is only
# stopped, not removed; its data is on /srv bind mounts.
if [[ "$running" == running ]]; then
  docker stop -t 10 "$CONTAINER" >/dev/null
  docker update --restart=no "$CONTAINER" >/dev/null
  echo "stopped $CONTAINER (restart policy set to no; the vault tools are down until filler-up below)"
else
  echo "not running"
fi

echo "== 6/6 ownership"
chown "$ACCT:$ACCT" "$ROOT"; chmod 0755 "$ROOT"
install -d -o "$ACCT" -g "$ACCT" -m 0755 "$ROOT/releases"
chown "$ACCT:$ACCT" "$ROOT/releases"
[[ -L "$ROOT/current" ]] && chown -h "$ACCT:$ACCT" "$ROOT/current"
chown -R "$ACCT:$ACCT" "$ROOT/policy-backups"; chmod 0700 "$ROOT/policy-backups"
install -d -o "$ACCT" -g "$ACCT" -m 0700 "$ROOT/state" "$ROOT/trash"
[[ -d "$ROOT/secrets" ]] || install -d -o "$ACCT" -g "$ACCT" -m 0500 "$ROOT/secrets"
install -d -o "$ACCT" -g "$OP_GROUP" -m 2750 "$ROOT/audit"
chown "$ACCT:$OP_GROUP" "$ROOT/audit"; chmod 2750 "$ROOT/audit"
if [[ -e "$ROOT/policy.json" ]]; then chown "$ACCT:$ACCT" "$ROOT/policy.json"; chmod 0640 "$ROOT/policy.json"; fi
# outbox/: tokens for prep (group prep may move them out). inbox/: prep drops
# the controller token (group prep may add, not list; sticky).
install -d -o "$ACCT" -g "$OP_GROUP" -m 2770 "$ROOT/outbox"
chown "$ACCT:$OP_GROUP" "$ROOT/outbox"; chmod 2770 "$ROOT/outbox"
install -d -o "$ACCT" -g "$OP_GROUP" -m 3730 "$ROOT/inbox"
chown "$ACCT:$OP_GROUP" "$ROOT/inbox"; chmod 3730 "$ROOT/inbox"
# Old releases stay root-owned and read-only.
if runuser -u "$OP" -- test -w "$ROOT/policy.json" 2>/dev/null; then die "$OP can write policy.json"; fi
if runuser -u "$OP" -- ls "$ROOT/secrets" >/dev/null 2>&1; then die "$OP can list secrets/"; fi
echo "owner of $ROOT: $ACCT; audit/ 2750, outbox/ 2770, inbox/ 3730 with group $OP_GROUP"
echo "id $ACCT: $(id "$ACCT")"
echo
echo "done; sudo is not needed again. Next, with no sudo:"
echo "  su - $ACCT"
echo "  make -C $REPO/selfhost filler-install COMMIT=<sha>"
echo "  make -C $REPO/selfhost filler-up"
echo "  exit"
echo "  make filler-status        (as $OP)"
echo "To go back to the docker filler instead: as $OP, docker start $CONTAINER (after chowning policy.json"
echo "back to root, which needs root again; the old policy is in $B)."
