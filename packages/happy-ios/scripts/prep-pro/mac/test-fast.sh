#!/bin/zsh
# Fast simulator test run for happy-ios on prep-pro. Started by remote.sh
# (make ios-test-fast); usage: test-fast.sh <run-ts>
#
#  1. build-for-testing once (scheme HappySimTests: hosted + UIKit tests),
#     Debug, arm64 only, into a persistent DerivedData, while the simulator
#     pool boots;
#  2. the Debug device compile check starts in its own DerivedData;
#  3. the test classes run in WORKERS parallel shards (test-without-building
#     -only-testing), one pre-booted simulator each, balanced by measured
#     class durations;
#  4. the timing-sensitive classes (serial-tests.txt) run alone afterwards;
#  5. classes that failed in parallel are re-run alone once, and reported;
#  6. results are merged and checked against the enumerated test list.
#
# Knobs (environment): WORKERS=4  CLEAN=0  CACHE=0  DEVICE=1  RETRY=1
#   KEEP_SIMS=0  WAIT_FOREIGN=1  WAIT_MAX=7200
set -u
HERE=${0:A:h}
source $HERE/common.sh
TS=$1
R=$HF/runs/$TS
L=$R/logs
mkdir -p $L
exec > >(tee -a $R/run.log) 2>&1

P=$HF/trees/sim/packages/happy-ios
DD=$HF/dd/sim-debug
DDD=$HF/dd/device-debug
WORKERS=${WORKERS:-4}
SECONDS=0
typeset -A T

finish() {
  local rc=$1
  [[ ${KEEP_SIMS:-0} == 1 ]] || for id in ${SIMS[@]:-}; do xcrun simctl shutdown $id > /dev/null 2>&1; done
  release_lock
  {
    print "timings (s):"
    for k in ${(ok)T}; do printf '  %-22s %5d\n' $k ${T[$k]}; done
    printf '  %-22s %5d\n' total $SECONDS
  } | tee $R/timings.txt
  print -r -- $rc > $R/exit
  log "TEST-FAST EXIT $rc"
  exit $rc
}
trap 'finish 130' INT TERM

log "run $TS, commit $(cat $HF/trees/sim/SOURCE_COMMIT 2>/dev/null)"
wait_for_foreign_xcodebuild || finish 75
acquire_lock "test-fast $TS"
T[0_wait_lock]=$SECONDS

SIMS=($(sim_ids $WORKERS)) || finish 70
log "simulators: ${SIMS[*]}"
BOOT_PIDS=()
for id in $SIMS; do boot_sim $id & BOOT_PIDS+=($!); done

maybe_clean $DD
[[ ${DEVICE:-1} == 1 ]] && maybe_clean $DDD
seed_packages $DD
t0=$SECONDS
gen_project $P $HF/xcodegen-cache-sim > $L/xcodegen.log 2>&1 || { log "xcodegen failed"; cat $L/xcodegen.log; finish 2; }
T[1_xcodegen]=$((SECONDS - t0))
resolve_packages $P $DD HappySimTests || finish 2

COMMON=(CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 ${=$(cache_settings)})
log "build-for-testing (Debug, arm64) -> $DD"
t0=$SECONDS
xcodebuild build-for-testing -project $P/Happy.xcodeproj -scheme HappySimTests -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath $DD -skipPackageUpdates \
  -showBuildTimingSummary $COMMON > $L/build-for-testing.log 2>&1
rc=$?
T[2_build_for_testing]=$((SECONDS - t0))
if (( rc != 0 )); then
  log "build-for-testing failed ($rc):"; grep -E 'error:|BUILD FAILED' $L/build-for-testing.log | head -30
  finish 3
fi
log "build-for-testing done in ${T[2_build_for_testing]} s"

DEV_PID=
if [[ ${DEVICE:-1} == 1 ]]; then
  seed_packages $DDD
  resolve_packages $P $DDD Happy || finish 2
  log "device compile check (Debug, generic iOS) -> $DDD, in the background"
  ( s=$SECONDS
    xcodebuild build -project $P/Happy.xcodeproj -scheme Happy -configuration Debug \
      -destination 'generic/platform=iOS' -derivedDataPath $DDD -skipPackageUpdates \
      -showBuildTimingSummary CODE_SIGNING_ALLOWED=NO ${=$(cache_settings)} > $L/device-debug.log 2>&1
    r=$?; print -r -- "$r $((SECONDS - s))" > $R/device-debug.exit ) &
  DEV_PID=$!
fi

XTR=$(ls -t $DD/Build/Products/HappySimTests_*.xctestrun 2>/dev/null | head -1)
[[ -n $XTR ]] || { log "no xctestrun in $DD/Build/Products"; finish 4; }

t0=$SECONDS
for p in $BOOT_PIDS; do wait $p; done
T[3_boot_wait]=$((SECONDS - t0))

t0=$SECONDS
xcodebuild test-without-building -xctestrun $XTR -destination "platform=iOS Simulator,id=${SIMS[1]}" \
  -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
  -test-enumeration-output-path $R/enumerated.json > $L/enumerate.log 2>&1 \
  || { log "test enumeration failed"; tail -20 $L/enumerate.log; finish 5; }
/usr/bin/python3 $HERE/shards.py plan --tests $R/enumerated.json --serial $HERE/../serial-tests.txt \
  --timings $HF/timings.tsv --workers $WORKERS --out $R/plan || finish 5
T[4_enumerate_plan]=$((SECONDS - t0))

run_shard() {  # name sim listfile
  local name=$1 sim=$2 list=$3 args=()
  for c in ${(f)"$(cat $list)"}; do args+=(-only-testing:$c); done
  xcodebuild test-without-building -xctestrun $XTR -destination "platform=iOS Simulator,id=$sim" \
    -parallel-testing-enabled NO -resultBundlePath $R/$name.xcresult $args > $L/$name.log 2>&1
  print -r -- $? > $R/$name.exit
}

log "parallel shards on $WORKERS simulators"
t0=$SECONDS
SH_PIDS=()
LOGS=()
for i in $(seq 1 $WORKERS); do
  [[ -s $R/plan/shard-$i.txt ]] || continue
  run_shard shard-$i ${SIMS[$i]} $R/plan/shard-$i.txt & SH_PIDS+=($!)
  LOGS+=(--log shard-$i=$L/shard-$i.log)
done
for p in $SH_PIDS; do wait $p; done
T[5_parallel_shards]=$((SECONDS - t0))
log "parallel shards done in ${T[5_parallel_shards]} s"

if [[ -n $DEV_PID ]]; then
  t0=$SECONDS
  wait $DEV_PID
  T[6_device_wait]=$((SECONDS - t0))
  read DEV_RC DEV_SECS < $R/device-debug.exit
  T[6_device_build]=$DEV_SECS
  log "device compile check exit $DEV_RC (${DEV_SECS} s)"
fi

# The serial shard runs alone: free the other simulators first.
[[ ${KEEP_SIMS:-0} == 1 ]] || for id in ${SIMS[2,-1]}; do xcrun simctl shutdown $id > /dev/null 2>&1; done
if [[ -s $R/plan/shard-serial.txt ]]; then
  log "serial shard (timing-sensitive classes) alone on ${SIMS[1]}"
  t0=$SECONDS
  run_shard shard-serial ${SIMS[1]} $R/plan/shard-serial.txt
  T[7_serial_shard]=$((SECONDS - t0))
  LOGS+=(--log serial=$L/shard-serial.log)
fi

/usr/bin/python3 $HERE/shards.py report --expected $R/plan/expected.txt $LOGS \
  --failed-classes $R/failed-classes.txt > /dev/null
if [[ ${RETRY:-1} == 1 && -s $R/failed-classes.txt ]]; then
  n=$(wc -l < $R/failed-classes.txt)
  if (( n <= 20 )); then
    log "re-running $n failed class(es) alone"
    t0=$SECONDS
    run_shard rerun ${SIMS[1]} $R/failed-classes.txt
    T[8_rerun]=$((SECONDS - t0))
  else
    log "$n classes failed: not re-running"
  fi
fi

RERUN=()
[[ -f $L/rerun.log ]] && RERUN=(--rerun $L/rerun.log)
/usr/bin/python3 $HERE/shards.py report --expected $R/plan/expected.txt $LOGS $RERUN \
  --summary $R/summary.txt --results-json $R/results.json --timings $HF/timings.tsv
TRC=$?

XCR=($R/shard-*.xcresult(N/))
if (( ${#XCR} > 1 )); then
  xcrun xcresulttool merge $XCR --output-path $R/merged.xcresult > $L/merge.log 2>&1 \
    && log "merged result bundle: $R/merged.xcresult" || log "xcresult merge failed (see $L/merge.log)"
fi

RC=$TRC
if [[ -n $DEV_PID && ${DEV_RC:-0} != 0 ]]; then
  log "DEVICE COMPILE CHECK FAILED:"; grep -E 'error:' $L/device-debug.log | head -20
  RC=6
fi
finish $RC
