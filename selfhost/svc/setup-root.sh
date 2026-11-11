#!/usr/bin/env bash
# The one root step for the happy-svc rootless Docker daemon (selfhost/svc/README.md).
# Run once by you, from the operator account (prep), with sudo; agents never run it:
#
#   sudo bash selfhost/svc/setup-root.sh --commit <40-hex sha> [--settings DIR]
#                                        [--install-packages] [--dry-run]
#
# make svc-setup-print prints this line with the right values. Idempotent: a re-run checks
# each step and finishes what is missing. It never deletes anything and never reads or
# changes the operator's data or Docker. Steps:
#
#   1 preflight     root via sudo; kernel user namespaces; cgroup version; the packages
#                   (uidmap, dbus-user-session, slirp4netns, docker-ce-rootless-extras,
#                   docker-compose-plugin, jq, curl), installed only with --install-packages;
#                   the operator's root-equivalent groups (reported, not changed)
#   2 account       system user and group happy-svc: home /var/lib/happy-svc (0700), shell
#                   nologin, password locked, in no other group
#   3 subids        a 65536-wide subuid and subgid range that overlaps no other range or uid
#   4 release       deploy-root.sh <sha>: /opt/happy-svc/releases/<sha>, current -> it,
#                   and the settings with --settings
#   5 wrapper       /usr/local/libexec/happy-svc-ctl (root:root 0755), from the release
#   6 drop          /var/lib/happy-svc-drop (root, 0755) with in/ (happy-svc:<operator> 3770)
#   7 linger        loginctl enable-linger happy-svc; its user manager running
#   8 docker        the user units (rootless dockerd, port publishing, nightly backup) and
#                   daemon.json from the release, enabled and started as happy-svc
#   9 sudoers       /etc/sudoers.d/happy-svc (0440), checked with visudo -cf before it is
#                   moved into place, then visudo -c on the whole configuration
#  10 verify        as the operator: the wrapper answers through sudo -n; the operator cannot
#                   read ~happy-svc or reach its Docker socket
set -euo pipefail

ACCT=happy-svc
HOMED=/var/lib/happy-svc
OPT=/opt/happy-svc
CTL=/usr/local/libexec/happy-svc-ctl
DROP=/var/lib/happy-svc-drop
SUDOERS=/etc/sudoers.d/happy-svc
SUBID_COUNT=65536
PKGS=(uidmap dbus-user-session slirp4netns docker-ce-rootless-extras docker-compose-plugin jq curl)
ROOT_GROUPS="sudo docker lxd adm admin wheel root disk"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { echo "setup-root: $*" >&2; exit 1; }
SHA="" SETTINGS="" DRY=0 INSTALL=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY=1 ;;
        --install-packages) INSTALL=1 ;;
        --commit) [[ $# -ge 2 ]] || die "--commit needs a sha"; SHA=$2; shift ;;
        --settings) [[ $# -ge 2 ]] || die "--settings needs a directory"; SETTINGS=$2; shift ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument (see --help)" ;;
    esac
    shift
done
[[ -z $SHA || $SHA =~ ^[0-9a-f]{40}$ ]] || die "--commit takes a full 40-hex sha"
[[ $EUID -eq 0 ]] || die "run with sudo (make svc-setup-print shows the command)"
OP=${SUDO_USER:?run through sudo from the operator account}
[[ $OP =~ ^[a-z_][a-z0-9_-]{0,31}$ && $OP != root ]] || die "run through sudo from the operator account, not root"
OP_GROUP=$(id -gn "$OP")

run() { if [[ $DRY == 1 ]]; then printf '  would: %s\n' "$*"; else "$@"; fi; }
step() { echo; echo "== $*"; }
[[ $DRY == 1 ]] && echo "DRY RUN: every change below is printed, not made."
echo "operator: $OP   account: $ACCT   commit: ${SHA:-(keep current release)}"

step "1/10 preflight"
[[ $(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1) == 1 ]] || die "kernel.unprivileged_userns_clone is 0"
[[ $(cat /proc/sys/user/max_user_namespaces) -gt 0 ]] || die "user.max_user_namespaces is 0"
if [[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]]; then echo "cgroup: v2"; else
    echo "cgroup: v1. Rootless Docker cannot apply cgroup limits on v1: pids_limit, memory and"
    echo "        cpu limits in the compose files are ignored (README, Open risks)."
fi
missing=()
for p in "${PKGS[@]}"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "missing packages: ${missing[*]}"
    [[ $INSTALL == 1 ]] || die "install them (apt-get install ${missing[*]}) or re-run with --install-packages"
    run apt-get install -y --no-install-recommends "${missing[@]}"
else
    echo "packages: all present (${PKGS[*]})"
fi
for g in $(id -nG "$OP"); do
    for b in docker lxd; do
        [[ $g == "$b" ]] && echo "WARNING: $OP is in group $b, which is root in effect. Agents running as $OP can still reach every file through it. README, Cutover step 6."
    done
done

step "2/10 account"
if getent passwd "$ACCT" >/dev/null; then
    echo "$ACCT exists: $(id "$ACCT")"
    [[ $(getent passwd "$ACCT" | cut -d: -f6) == "$HOMED" ]] || die "$ACCT exists with a home other than $HOMED"
else
    getent group "$ACCT" >/dev/null || run groupadd --system "$ACCT"
    run useradd --system --gid "$ACCT" --home-dir "$HOMED" --create-home --shell /usr/sbin/nologin \
        --comment "Happy services (rootless Docker)" "$ACCT"
fi
run install -d -o "$ACCT" -g "$ACCT" -m 0700 "$HOMED"
run passwd -l "$ACCT" >/dev/null
if getent passwd "$ACCT" >/dev/null; then
    for g in $(id -nG "$ACCT"); do
        [[ $g == "$ACCT" ]] && continue
        for b in $ROOT_GROUPS; do [[ $g != "$b" ]] || die "$ACCT is in group $b; take it out (gpasswd -d $ACCT $b) and re-run"; done
        die "$ACCT is in group $g; it should be in its own group only"
    done
fi

step "3/10 subuid / subgid"
# rootlesskit maps container uids to this range; it must not overlap another user's range or
# any real uid. The new range starts after every existing one, on a 65536 boundary.
if grep -q "^$ACCT:" /etc/subuid && grep -q "^$ACCT:" /etc/subgid; then
    echo "existing: $(grep "^$ACCT:" /etc/subuid) / $(grep "^$ACCT:" /etc/subgid)"
    for f in /etc/subuid /etc/subgid; do
        [[ $(grep "^$ACCT:" "$f" | head -1 | cut -d: -f3) -ge $SUBID_COUNT ]] || die "$f: the $ACCT range is smaller than $SUBID_COUNT"
    done
else
    end=$(awk -F: 'NF==3 { e=$2+$3; if (e>m) m=e } END { print m+0 }' /etc/subuid /etc/subgid)
    start=$(( (end + SUBID_COUNT - 1) / SUBID_COUNT * SUBID_COUNT ))
    [[ $start -lt 100000 ]] && start=100000
    last=$((start + SUBID_COUNT - 1))
    [[ $last -lt 4294967294 ]] || die "no room for a subuid range"
    if getent passwd | awk -F: -v s="$start" -v e="$last" '$3>=s && $3<=e {f=1} END {exit !f}'; then die "uid range $start-$last holds a real uid"; fi
    if getent group | awk -F: -v s="$start" -v e="$last" '$3>=s && $3<=e {f=1} END {exit !f}'; then die "gid range $start-$last holds a real gid"; fi
    echo "new range: $start-$last"
    run usermod --add-subuids "$start-$last" --add-subgids "$start-$last" "$ACCT"
fi

step "4/10 release"
if [[ -n $SHA ]]; then
    args=("$SHA"); [[ -n $SETTINGS ]] && args+=(--settings "$SETTINGS"); [[ $DRY == 1 ]] && args+=(--dry-run)
    bash "$HERE/deploy-root.sh" "${args[@]}"
else
    [[ -d $OPT/current/selfhost/svc ]] || die "no release yet; pass --commit <sha>"
    echo "keeping $(readlink "$OPT/current")"
fi
# From here on every file installed comes from the root-owned release, not the working tree.
REL=$OPT/current/selfhost/svc
if [[ $DRY == 1 && ! -d $REL ]]; then REL=$HERE; else
    # This script and deploy-root.sh ran from the working tree; they must be the release's own.
    for f in setup-root.sh deploy-root.sh; do
        cmp -s "$HERE/$f" "$REL/$f" || die "$HERE/$f differs from the release's copy; it is not the reviewed commit. Stopping before the wrapper and sudoers."
    done
fi

step "5/10 wrapper"
run install -d -o root -g root -m 0755 /usr/local/libexec
run install -o root -g root -m 0755 "$REL/happy-svc-ctl" "$CTL"
echo "$CTL from $REL"

step "6/10 drop directory"
# in/: the operator may add files (setgid: they keep group $OP_GROUP; sticky: only their
# owner or happy-svc may move them); happy-svc reads and moves them out on import.
run install -d -o root -g root -m 0755 "$DROP"
run install -d -o "$ACCT" -g "$OP_GROUP" -m 3770 "$DROP/in"
run chown "$ACCT:$OP_GROUP" "$DROP/in"
run chmod 3770 "$DROP/in"

step "7/10 linger"
run loginctl enable-linger "$ACCT"
SUID=$(id -u "$ACCT" 2>/dev/null || echo 0)
RUNDIR=/run/user/$SUID
if [[ $DRY == 0 ]]; then
    systemctl start "user@$SUID.service"
    for _ in $(seq 1 40); do [[ -S $RUNDIR/systemd/private && -S $RUNDIR/bus ]] && break; sleep 0.5; done
    [[ -S $RUNDIR/systemd/private ]] || die "the user manager of $ACCT did not come up"
    echo "user@$SUID.service running"
fi

step "8/10 rootless docker"
asvc() { run runuser -u "$ACCT" -- env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOMED" \
    XDG_RUNTIME_DIR="$RUNDIR" DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNDIR/bus" "$@"; }
UNITS=$HOMED/.config/systemd/user
for d in "$HOMED/.config" "$UNITS" "$HOMED/.config/docker" "$HOMED/data" "$HOMED/backups"; do
    run install -d -o "$ACCT" -g "$ACCT" -m 0700 "$d"
done
ts=$(date -u +%Y%m%dT%H%M%SZ)
inst() {   # source, destination: replaced only if different, the old one kept beside it
    if [[ -e $2 ]] && ! cmp -s "$1" "$2"; then run install -d -o "$ACCT" -g "$ACCT" -m 0700 "$HOMED/old-config/$ts"; run mv "$2" "$HOMED/old-config/$ts/"; fi
    run install -o "$ACCT" -g "$ACCT" -m 0600 "$1" "$2"
}
for u in docker.service happy-svc-ports.service happy-svc-backup.service happy-svc-backup.timer; do inst "$REL/systemd/$u" "$UNITS/$u"; done
inst "$REL/systemd/daemon.json" "$HOMED/.config/docker/daemon.json"
asvc systemctl --user daemon-reload
asvc systemctl --user enable --now docker.service
asvc systemctl --user enable happy-svc-ports.service happy-svc-backup.timer
asvc systemctl --user start happy-svc-backup.timer
if [[ $DRY == 0 ]]; then
    for _ in $(seq 1 60); do [[ -S $RUNDIR/docker.sock ]] && break; sleep 0.5; done
    [[ -S $RUNDIR/docker.sock ]] || die "rootless dockerd did not come up; journalctl --user -u docker as $ACCT (machinectl shell $ACCT@)"
    asvc docker --host "unix://$RUNDIR/docker.sock" info -f 'daemon {{.ServerVersion}}: {{.SecurityOptions}}'
fi

step "9/10 sudoers"
tmp=$SUDOERS.new   # a name with a dot: sudo ignores it until it is moved into place
if [[ $DRY == 1 ]]; then
    echo "  would: write $tmp from $REL/sudoers.happy-svc (operator $OP), visudo -cf, mv to $SUDOERS"
    sed "s/@OPERATOR@/$OP/g" "$REL/sudoers.happy-svc" | grep -v '^#' | sed 's/^/    /'
else
    (umask 0337; sed "s/@OPERATOR@/$OP/g" "$REL/sudoers.happy-svc" >"$tmp")
    chown root:root "$tmp"; chmod 0440 "$tmp"
    visudo -cf "$tmp" >/dev/null || { mv "$tmp" "$tmp.rejected-$ts"; die "visudo rejected it (kept as $tmp.rejected-$ts)"; }
    if [[ -e $SUDOERS ]] && ! cmp -s "$tmp" "$SUDOERS"; then
        install -d -o root -g root -m 0700 /var/lib/happy-svc-old
        mv "$SUDOERS" "/var/lib/happy-svc-old/sudoers-$ts"
    fi
    mv -f "$tmp" "$SUDOERS"
    visudo -c >/dev/null || die "visudo -c fails with $SUDOERS in place; move it out of /etc/sudoers.d now"
    echo "$SUDOERS installed"
fi

step "10/10 verify"
if [[ $DRY == 0 ]]; then
    runuser -u "$OP" -- sudo -n -u "$ACCT" "$CTL" status >/dev/null 2>&1 \
        && echo "ok: $OP runs the wrapper with sudo -n" || echo "NOTE: the status check did not pass yet (expected before the first svc-up)"
    runuser -u "$OP" -- test -r "$HOMED" && die "$OP can read $HOMED"
    runuser -u "$OP" -- test -e "$RUNDIR/docker.sock" && die "$OP can reach $RUNDIR/docker.sock"
    runuser -u "$OP" -- sudo -n -u "$ACCT" /bin/sh -c true 2>/dev/null && die "$OP can run a shell as $ACCT without a password"
    runuser -u "$OP" -- sudo -n -u "$ACCT" "$CTL" import x 2>/dev/null && die "$OP can run import without a password"
    echo "ok: $OP cannot read $HOMED, reach the socket, or run anything else as $ACCT without a password"
fi
echo
echo "done. Next, as $OP (no sudo): make -C /home/$OP/happy/selfhost svc-status"
echo "Cutover and migration: selfhost/svc/README.md"
