#!/usr/bin/env bash
# Put one commit of the repo into /opt/happy-svc/releases/<sha> (root-owned, read-only to
# everyone else) and point /opt/happy-svc/current at it. Run by you, with sudo; agents never
# run it. setup-root.sh calls it for the first release.
#
#   sudo bash selfhost/svc/deploy-root.sh <40-hex sha> [--settings DIR] [--dry-run]
#   bash selfhost/svc/deploy-root.sh --check-settings DIR     (no root: only the settings check)
#
# The sha is the whole trust decision: you name a commit you have reviewed. The objects come
# from the operator's checkout, packed by the operator's own git (run as that user, never as
# root): the commit, the trees down to RELEASE_PATHS and everything under them, no history.
# They are unpacked into a root-owned object store (/opt/happy-svc/src.git), where git checks
# every object's hash. So whatever the checkout holds, the tree that lands is exactly that commit's, or
# nothing. Root runs git only in its own repository with no system or global config.
#
# Only the paths the stack needs are copied (RELEASE_PATHS). Old releases are kept, never
# removed; rolling back is deploying an older sha again (it is already there; the switch is
# instant).
#
# --settings DIR: also install DIR/vault.env and DIR/browser.env (from make svc-settings) as
# /etc/happy-svc/{vault,browser}.env. Only the keys listed below are accepted; paths, ports,
# uids and the LAN listener are fixed by happy-svc-ctl and cannot be set this way. Some keys
# take only certain values (check_value): BROWSER_NODE_CHROME 0 or 1, SCREENSHOT_TIME_MODE
# desktop or tab, EVIDENCE_TZ a zone in /usr/share/zoneinfo. There is no BROWSER_NODE_IMAGE:
# with BROWSER_NODE_CHROME=1, happy-svc-ctl builds the node image from the release's
# node-chrome/Dockerfile in happy-svc's daemon and names it by its image id itself.
set -euo pipefail

RELEASE_PATHS=(selfhost/svc selfhost/vault browser-stack)
VAULT_KEYS=" VAULT_DOMAIN VAULT_AGENT_EMAIL VAULT_OWNER_EMAIL "
BROWSER_KEYS=" BROWSER_WIDTH BROWSER_HEIGHT BROWSER_KIOSK BROWSER_VIEWPORT_HEIGHT MAX_SESSIONS MCP_TOOL_PROFILE LOG_LEVEL REQUEST_RATE_LIMIT_REQUESTS PII_SCRUB_SCREENSHOT BRIDGE_PODS BRIDGE_MAX_PODS BRIDGE_POD_WARM BRIDGE_POD_IDLE_MIN BRIDGE_LINK_IDLE_HOURS BROWSER_NODE_CHROME EVIDENCE_TZ SCREENSHOT_TIME_MODE "
ZONEINFO=/usr/share/zoneinfo
OPT=/opt/happy-svc
ETC=/etc/happy-svc

die() { echo "deploy-root: $*" >&2; exit 1; }

# A zone name of the host's tzdata: letters, digits, _ + - in up to three /-separated parts
# (so no "..", no leading /, no dots at all), a TZif file under $ZONEINFO once links are
# followed, and not one of the posix/ or right/ copies.
valid_tz() {
    local z=$1 f
    [[ ${#z} -le 64 && $z =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,2}$ ]] || return 1
    [[ $z != posix/* && $z != right/* && $z != posixrules ]] || return 1
    f=$(realpath -e -- "$ZONEINFO/$z" 2>/dev/null) || return 1
    [[ $f == "$ZONEINFO"/* && -f $f ]] || return 1
    [[ $(head -c 4 -- "$f") == TZif ]]
}
# Keys that take only certain values (and what they take); every other accepted key is checked
# by check_env alone.
check_value() {   # key, value
    case $1 in
        BROWSER_NODE_CHROME) [[ $2 == 0 || $2 == 1 ]] ;;
        SCREENSHOT_TIME_MODE) [[ $2 == desktop || $2 == tab ]] ;;
        EVIDENCE_TZ) valid_tz "$2" ;;
    esac
}
value_rule() {
    case $1 in
        BROWSER_NODE_CHROME) echo "0 or 1" ;;
        SCREENSHOT_TIME_MODE) echo "desktop or tab" ;;
        EVIDENCE_TZ) echo "a zone in $ZONEINFO" ;;
    esac
}
check_env() {   # file, allowed keys
    local f=$1 keys=$2 line k
    [[ -f $f && ! -L $f ]] || die "$f: not a regular file"
    [[ $(stat -c %s "$f") -le 8192 ]] || die "$f: too large"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == '#'* ]] && continue
        [[ $line =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9@._:,/+-]*)$ ]] || die "$f: line refused (KEY=plain value only)"
        k=${BASH_REMATCH[1]}
        [[ $keys == *" $k "* ]] || die "$f: key $k is not accepted here"
        check_value "$k" "${BASH_REMATCH[2]}" || die "$f: $k is $(value_rule "$k")"
    done <"$f"
}
check_settings() {
    check_env "$1/vault.env" "$VAULT_KEYS"
    check_env "$1/browser.env" "$BROWSER_KEYS"
}

if [[ ${1:-} == --check-settings ]]; then
    [[ $# -eq 2 ]] || die "usage: deploy-root.sh --check-settings DIR"
    check_settings "$2"
    echo "deploy-root: $2/{vault,browser}.env accepted"
    exit 0
fi

SHA="" SETTINGS="" DRY=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY=1 ;;
        --settings) [[ $# -ge 2 ]] || die "--settings needs a directory"; SETTINGS=$2; shift ;;
        *) [[ -z $SHA ]] || die "one sha only"; SHA=$1 ;;
    esac
    shift
done
[[ $SHA =~ ^[0-9a-f]{40}$ ]] || die "usage: deploy-root.sh <40-hex sha> [--settings DIR] [--dry-run]"
if [[ -n $SETTINGS ]]; then check_settings "$SETTINGS"; fi
[[ $EUID -eq 0 ]] || die "run with sudo"
OP=${SUDO_USER:?run through sudo from the operator account}
[[ $OP =~ ^[a-z_][a-z0-9_-]{0,31}$ && $OP != root ]] || die "run through sudo from the operator account, not root"
REPO=${HAPPY_SVC_REPO:-/home/$OP/happy}
[[ -d $REPO/.git ]] || die "no checkout at $REPO (HAPPY_SVC_REPO=...)"

rgit() { env -i PATH=/usr/bin:/bin HOME=/nonexistent GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    git --git-dir="$OPT/src.git" -c core.hooksPath=/dev/null "$@"; }
run() { if [[ $DRY == 1 ]]; then printf '  would: %s\n' "$*"; else "$@"; fi; }

echo "== deploy $SHA from $REPO (packed as $OP)"
echo "   paths: ${RELEASE_PATHS[*]}"
[[ $DRY == 1 ]] && echo "   (dry run: nothing is changed)"

if [[ -e $OPT/releases/$SHA ]]; then
    echo "   release $SHA is already there; only switching current"
else
    run install -d -o root -g root -m 0755 "$OPT" "$OPT/releases"
    if [[ ! -d $OPT/src.git ]]; then run env -i PATH=/usr/bin:/bin HOME=/nonexistent git init -q --bare "$OPT/src.git"; fi
    run chmod 0700 "$OPT/src.git"
    # The operator's git lists and packs the commit, its root tree and the trees and blobs
    # under RELEASE_PATHS; root's git checks and stores them.
    asop() { runuser -u "$OP" -- env -i PATH=/usr/bin:/bin HOME="/home/$OP" git -C "$REPO" "$@"; }
    pack() {
        { echo "$SHA"; asop rev-parse "$SHA^{tree}"; asop ls-tree -r -t "$SHA" -- "${RELEASE_PATHS[@]}" | awk '{print $3}'; } \
            | asop pack-objects --stdout -q | rgit index-pack --stdin >/dev/null
    }
    if [[ $DRY == 1 ]]; then echo "  would: pack $SHA in $REPO as $OP, index-pack into $OPT/src.git"; else pack; fi
    if [[ $DRY == 0 ]]; then
        [[ $(rgit cat-file -t "$SHA") == commit ]] || die "$SHA is not a commit"
        # Its subject, for you to match against what you reviewed (no history is copied, so no git log).
        echo "   commit subject: $(rgit cat-file -p "$SHA" | sed -n '/^$/{n;p;q}')"
        stage=$OPT/releases/.stage-$SHA
        [[ ! -e $stage ]] || mv "$stage" "$OPT/releases/.failed-$SHA-$(date -u +%Y%m%dT%H%M%SZ)"
        install -d -o root -g root -m 0755 "$stage"
        # One subtree at a time (SHA:path), so git reads only the objects that were packed.
        for p in "${RELEASE_PATHS[@]}"; do
            rgit archive --format=tar --prefix="$p/" "$SHA:$p" \
                | (umask 022; tar -x --no-same-owner --no-same-permissions -C "$stage")
        done
        find "$stage" -perm /6000 -exec chmod ug-s {} +
        chown -R -h root:root "$stage"
        chmod -R go-w "$stage"
        while IFS= read -r l; do
            echo "   note: absolute symlink ${l#"$stage"/} -> $(readlink "$l")"
        done < <(find "$stage" -type l -lname '/*')
        printf 'sha=%s\ndeployed=%s\nby=%s\n' "$SHA" "$(date -u +%FT%TZ)" "$OP" >"$stage/.release"
        chmod 0644 "$stage/.release"
        mv -T "$stage" "$OPT/releases/$SHA"
    fi
fi

prev=$(readlink "$OPT/current" 2>/dev/null || true)
run ln -sfn "releases/$SHA" "$OPT/.current.new"
run mv -T "$OPT/.current.new" "$OPT/current"
echo "   current: ${prev:-none} -> releases/$SHA"

# --- settings (checked before anything is changed, above)
if [[ -n $SETTINGS ]]; then
    run install -d -o root -g root -m 0755 "$ETC"
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    for n in vault.env browser.env; do
        if [[ -e $ETC/$n ]] && ! cmp -s "$ETC/$n" "$SETTINGS/$n"; then
            echo "   $n changes:"; diff -u "$ETC/$n" "$SETTINGS/$n" | sed 's/^/     /' || true
            run install -d -o root -g root -m 0700 "$ETC/old" "$ETC/old/$ts"
            run mv "$ETC/$n" "$ETC/old/$ts/$n"
        fi
        run install -o root -g root -m 0644 "$SETTINGS/$n" "$ETC/$n"
    done
    echo "   settings: $ETC/{vault,browser}.env"
fi
echo "done. Next, as $OP: make -C $REPO/selfhost svc-up"
