#!/usr/bin/env bash
# Undo setup-root.sh without destroying anything. Run by you, with sudo:
#
#   sudo bash selfhost/svc/teardown-root.sh [--move-data-aside] [--dry-run]
#
# Stops and disables the happy-svc user units (the services and the rootless dockerd), turns
# linger off, and moves the sudoers drop-in and the wrapper into a root-only trash directory,
# /var/lib/happy-svc-old/<ts>/, with a README saying what was there. After that the operator
# can no longer reach the daemon at all.
#
# Kept: the happy-svc account, its subuid range, ~happy-svc (volumes, data, backups), the
# releases in /opt/happy-svc and /etc/happy-svc. --move-data-aside also renames
# /var/lib/happy-svc/data to data.aside-<ts> (same filesystem, nothing copied or deleted), so a
# later setup starts with an empty browser home; Docker volumes stay where they are.
#
# Rollback to the operator's own Docker: README.md, "Rollback".
set -euo pipefail

ACCT=happy-svc
HOMED=/var/lib/happy-svc
CTL=/usr/local/libexec/happy-svc-ctl
SUDOERS=/etc/sudoers.d/happy-svc
OLD=/var/lib/happy-svc-old

die() { echo "teardown-root: $*" >&2; exit 1; }
DRY=0 ASIDE=0
for a in "$@"; do
    case $a in
        --dry-run) DRY=1 ;;
        --move-data-aside) ASIDE=1 ;;
        -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument (see --help)" ;;
    esac
done
[[ $EUID -eq 0 ]] || die "run with sudo"
run() { if [[ $DRY == 1 ]]; then printf '  would: %s\n' "$*"; else "$@"; fi; }
[[ $DRY == 1 ]] && echo "DRY RUN: every change below is printed, not made."
ts=$(date -u +%Y%m%dT%H%M%SZ)
trash=$OLD/$ts

echo "== 1/4 sudoers and wrapper first, so nothing new can start"
run install -d -o root -g root -m 0700 "$OLD" "$trash"
moved=()
for f in "$SUDOERS" "$CTL"; do
    if [[ -e $f ]]; then run mv "$f" "$trash/"; moved+=("$f"); fi
done
[[ $DRY == 1 ]] || visudo -c >/dev/null || echo "WARNING: visudo -c reports a problem unrelated to happy-svc"

echo "== 2/4 user units"
if SUID=$(id -u "$ACCT" 2>/dev/null); then
    RUNDIR=/run/user/$SUID
    if [[ -S $RUNDIR/bus ]]; then
        asvc() { run runuser -u "$ACCT" -- env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOMED" \
            XDG_RUNTIME_DIR="$RUNDIR" DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNDIR/bus" "$@"; }
        # Containers stop with the daemon; their volumes stay in ~happy-svc.
        asvc systemctl --user disable --now happy-svc-backup.timer happy-svc-ports.service || true
        asvc systemctl --user disable --now docker.service || true
    else
        echo "user manager of $ACCT not running; nothing to stop"
    fi
    echo "== 3/4 linger"
    run loginctl disable-linger "$ACCT"
    run systemctl stop "user@$SUID.service" || true
else
    echo "no $ACCT account; skipping units and linger"
fi

echo "== 4/4 data"
if [[ $ASIDE == 1 && -d $HOMED/data ]]; then
    run mv -T "$HOMED/data" "$HOMED/data.aside-$ts"
    echo "data moved to $HOMED/data.aside-$ts"
else
    echo "data kept in $HOMED"
fi

if [[ $DRY == 0 ]]; then
    {
        echo "teardown-root.sh at $ts by ${SUDO_USER:-root}"
        echo "Moved here (restore with mv, or re-run setup-root.sh):"
        for f in "${moved[@]}"; do echo "  $f"; done
        [[ $ASIDE == 1 ]] && echo "Data renamed: $HOMED/data -> $HOMED/data.aside-$ts"
        echo "Kept: the $ACCT account, its subuids, $HOMED, /opt/happy-svc, /etc/happy-svc."
    } >"$trash/README"
    chmod 0600 "$trash/README"
fi
cat <<EOF

done. Moved aside: ${moved[*]:-nothing} -> $trash
To bring it back: sudo bash selfhost/svc/setup-root.sh (re-installs from the current release).
To go back to your own Docker instead: selfhost/svc/README.md, "Rollback".
EOF
