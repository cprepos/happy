#!/usr/bin/env bash
# Drive the fast happy-ios builds on prep-pro from this Linux box.
# Use through make (packages/happy-ios/Makefile):
#   make ios-test-fast                 hosted + UIKit simulator tests, sharded, plus a Debug device compile check
#   make ios-test-fast CLEAN=1         same, from a cold DerivedData (the old one is moved to ~/happy-fast/trash)
#   make ios-build-device              unsigned Preview device build (PHONE_TS=<ts> hands it to sign.sh)
#   make ios-fast-attach RUN=<ts>      follow a run that is still going
#   make ios-fast-runs                 list recent runs
# COMMIT defaults to HEAD of this repo. Other knobs are passed through to the
# Mac scripts: WORKERS CLEAN CACHE DEVICE RETRY KEEP_SIMS WAIT_FOREIGN WAIT_MAX.
set -euo pipefail

HOST=${HOST:-prep-pro}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
SSH=(ssh -o BatchMode=yes -o ServerAliveInterval=30 "$HOST")
RHF='happy-fast'   # relative to the Mac home

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

passthrough_env() {
  local out=() v
  for v in WORKERS CLEAN CACHE DEVICE RETRY KEEP_SIMS WAIT_FOREIGN WAIT_MAX; do
    if [[ -n ${!v:-} ]]; then
      [[ ${!v} =~ ^[0-9]+$ ]] || { echo "$v must be a number" >&2; exit 2; }
      out+=("$v=${!v}")
    fi
  done
  echo "${out[*]:-}"
}

# Export packages/happy-ios at $1 into a scratch dir, optionally patch it for
# device signing, and sync it into ~/happy-fast/trees/$2 with checksums, so a
# file whose content did not change keeps its old mtime on the Mac and is not
# rebuilt. The generated Xcode project and SwiftPM state are left in place.
sync_tree() {
  local commit=$1 purpose=$2 patch=$3 stage
  stage=$(mktemp -d "${TMPDIR:-/tmp}/happy-ios-fast.XXXXXX")
  git -C "$REPO" archive "$commit" packages/happy-ios | tar -x -C "$stage"
  echo "$commit" > "$stage/SOURCE_COMMIT"
  if [[ $patch == device ]]; then
    # Same edits as .agents/skills/happy-ios-ota/prep.sh.template: the team,
    # the Preview bundle id the profile covers, and no entitlements.
    python3 - "$stage/packages/happy-ios" <<'PY'
import sys, os
p = sys.argv[1]
s = open(os.path.join(p, "project.yml")).read()
assert s.count('    SWIFT_VERSION: "6.0"\n') >= 1
s = s.replace('    SWIFT_VERSION: "6.0"\n', '    SWIFT_VERSION: "6.0"\n    DEVELOPMENT_TEAM: 74YS5XP5GW\n', 1)
b = "PRODUCT_BUNDLE_IDENTIFIER: com.slopus.happy.preview"
i = s.index("        Preview:\n          " + b)
s = s[:i] + s[i:].replace(b, "PRODUCT_BUNDLE_IDENTIFIER: org.girthbass.native", 1)
open(os.path.join(p, "project.yml"), "w").write(s)
open(os.path.join(p, "App/Happy.entitlements"), "w").write(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    '<plist version="1.0">\n<dict/>\n</plist>\n')
PY
  fi
  "${SSH[@]}" "mkdir -p $RHF/bin $RHF/runs $RHF/trees/$purpose"
  rsync -rlc --delete -e "ssh -o BatchMode=yes" "$HERE/mac" "$HERE/serial-tests.txt" "$HOST:$RHF/bin/"
  local changed
  changed=$(rsync -rlc --delete --itemize-changes -e "ssh -o BatchMode=yes" \
    --exclude=/packages/happy-ios/Happy.xcodeproj/ --exclude=.build/ --exclude=.swiftpm/ \
    "$stage/" "$HOST:$RHF/trees/$purpose/" | grep -c '^[<>c*]' || true)
  echo "synced $purpose tree at ${commit:0:9}: $changed path(s) changed"
  # The scratch export is a throwaway copy of a git commit.
  rm -rf "$stage"
}

follow() {
  local ts=$1 seen=0 n
  while true; do
    n=$("${SSH[@]}" "f=$RHF/runs/$ts/run.log; [ -f \$f ] && tail -n +$((seen + 1)) \$f; true" | tee /dev/stderr | wc -l) || n=0
    seen=$((seen + n))
    if "${SSH[@]}" "test -f $RHF/runs/$ts/exit" 2>/dev/null; then
      "${SSH[@]}" "f=$RHF/runs/$ts/run.log; tail -n +$((seen + 1)) \$f" >&2 || true
      local rc
      rc=$("${SSH[@]}" "cat $RHF/runs/$ts/exit")
      echo "logs: $HOST:~/$RHF/runs/$ts" >&2
      return "$rc"
    fi
    sleep 15
  done
}

launch() {
  local ts=$1; shift
  "${SSH[@]}" "mkdir -p $RHF/runs/$ts && cd $RHF && nohup env $(passthrough_env) /bin/zsh bin/mac/$* > runs/$ts/nohup.out 2>&1 < /dev/null &"
}

cmd=${1:-}; shift || true
case $cmd in
  test)
    C=$(git -C "$REPO" rev-parse "${COMMIT:-HEAD}^{commit}")
    TS=$(date +%Y%m%d_%H%M%S)
    sync_tree "$C" sim none
    launch "$TS" test-fast.sh "$TS"
    echo "run $TS started on $HOST (make ios-fast-attach RUN=$TS to follow it again)" >&2
    follow "$TS"
    ;;
  device)
    C=$(git -C "$REPO" rev-parse "${COMMIT:-HEAD}^{commit}")
    CONFIG=${CONFIG:-Preview}
    [[ $CONFIG =~ ^(Preview|Debug|Release)$ ]] || { echo "CONFIG must be Preview, Debug or Release" >&2; exit 2; }
    [[ -z ${PHONE_TS:-} || ${PHONE_TS} =~ ^[0-9]{8}_[0-9]{6}$ ]] || { echo "PHONE_TS must look like 20261104_120000" >&2; exit 2; }
    TS=$(date +%Y%m%d_%H%M%S)
    sync_tree "$C" "device-$(tr 'A-Z' 'a-z' <<< "$CONFIG")" device
    launch "$TS" build-device.sh "$TS" "$CONFIG" "${PHONE_TS:-}"
    echo "run $TS started on $HOST" >&2
    follow "$TS"
    ;;
  sync)
    # Stage the sim tree without building (cheap; safe while prep-pro is busy).
    sync_tree "$(git -C "$REPO" rev-parse "${COMMIT:-HEAD}^{commit}")" sim none
    ;;
  attach)
    [[ ${1:-} =~ ^[0-9]{8}_[0-9]{6}$ ]] || usage
    follow "$1"
    ;;
  runs)
    "${SSH[@]}" "cd $RHF/runs 2>/dev/null && for d in \$(ls -t | head -10); do printf '%s  exit=%s  %s\n' \$d \"\$(cat \$d/exit 2>/dev/null || echo running)\" \"\$(head -1 \$d/run.log 2>/dev/null | cut -c1-100)\"; done"
    ;;
  *) usage ;;
esac
