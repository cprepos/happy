#!/bin/zsh
# Device build of the Happy app on prep-pro, unsigned, from the persistent
# tree trees/device-<config> into the persistent DerivedData dd/device-<config>.
# Started by remote.sh (make ios-build-device); usage:
#   build-device.sh <run-ts> <Preview|Debug|Release> [phone-ts]
# With phone-ts, the built Happy.app is copied to
# ~/happy-phone-build/<phone-ts>/dd/Build/Products/<config>-iphoneos/, where
# the happy-ios-ota skill's sign.sh picks it up.
# Knobs: CLEAN=0 CACHE=0 WAIT_FOREIGN=1 WAIT_MAX=7200
set -u
HERE=${0:A:h}
source $HERE/common.sh
TS=$1
CONFIG=${2:-Preview}
PHONE_TS=${3:-}
R=$HF/runs/$TS
L=$R/logs
mkdir -p $L
exec > >(tee -a $R/run.log) 2>&1
CFG=${(L)CONFIG}
P=$HF/trees/device-$CFG/packages/happy-ios
DD=$HF/dd/device-$CFG
SECONDS=0

finish() {
  release_lock
  print -r -- "$1" > $R/exit
  log "DEVICE BUILD EXIT $1 (total ${SECONDS} s)"
  exit $1
}
trap 'finish 130' INT TERM

log "run $TS, $CONFIG device build, commit $(cat $HF/trees/device-$CFG/SOURCE_COMMIT 2>/dev/null)"
wait_for_foreign_xcodebuild || finish 75
acquire_lock "build-device $CONFIG $TS"
maybe_clean $DD
seed_packages $DD
gen_project $P $HF/xcodegen-cache-device-$CFG > $L/xcodegen.log 2>&1 || { cat $L/xcodegen.log; finish 2; }
resolve_packages $P $DD Happy || finish 2

t0=$SECONDS
xcodebuild build -project $P/Happy.xcodeproj -scheme Happy -configuration $CONFIG \
  -destination 'generic/platform=iOS' -derivedDataPath $DD -skipPackageUpdates \
  -showBuildTimingSummary CODE_SIGNING_ALLOWED=NO ${=$(cache_settings)} > $L/compile.log 2>&1
rc=$?
echo "COMPILE EXIT $rc" >> $L/compile.log
log "xcodebuild exit $rc in $((SECONDS - t0)) s"
if (( rc != 0 )); then grep -E 'error:|BUILD FAILED' $L/compile.log | head -30; finish 3; fi

APP=$DD/Build/Products/$CONFIG-iphoneos/Happy.app
if [[ -n $PHONE_TS ]]; then
  B=~/happy-phone-build/$PHONE_TS
  O=$B/dd/Build/Products/$CONFIG-iphoneos
  if [[ -e $O/Happy.app ]]; then log "$O/Happy.app already exists; use a new phone TS"; finish 91; fi
  mkdir -p $O $B/logs
  ditto $APP $O/Happy.app
  cp $HF/trees/device-$CFG/SOURCE_COMMIT $B/SOURCE_COMMIT
  cp $L/compile.log $B/logs/compile.log
  log "copied Happy.app to $O for sign.sh"
fi
finish 0
