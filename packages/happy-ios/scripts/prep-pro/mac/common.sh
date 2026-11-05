#!/bin/zsh
# Shared helpers for the fast happy-ios builds on prep-pro. Sourced, not run.
#
# Layout (everything under $HF, default ~/happy-fast):
#   bin/              these scripts, copied in by remote.sh on every run
#   trees/<purpose>/  one persistent source tree per purpose, updated in place
#                     with rsync -c, so files that did not change keep their mtime
#   dd/<config>/      one persistent DerivedData per configuration
#   cas/              shared compilation cache (only used when CACHE=1)
#   runs/<TS>/        logs, result bundles and the summary of one run
#   lock/             mkdir lock: one heavy happy-ios job at a time
#   timings.tsv       per-class test durations from the last runs (shard balance)

export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
HF=${HF:-$HOME/happy-fast}
SIM_PREFIX=${SIM_PREFIX:-happy-fast}
SIM_TYPE=${SIM_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}
SIM_RUNTIME=${SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}

log() { print -r -- "[$(date +%H:%M:%S)] $*"; }

# Wait while another xcodebuild runs (another agent's happy-ios job, or an
# unrelated Instimate build). WAIT_FOREIGN=0 skips the wait; WAIT_MAX bounds it.
wait_for_foreign_xcodebuild() {
  [[ ${WAIT_FOREIGN:-1} == 0 ]] && return 0
  local waited=0 max=${WAIT_MAX:-7200} busy
  while true; do
    busy=$(pgrep -fl '/usr/bin/xcodebuild ' 2>/dev/null | grep -v "$HF/" || true)
    [[ -z $busy ]] && return 0
    if (( waited == 0 || waited % 60 == 0 )); then
      log "waiting for another xcodebuild to finish (${waited}s):"
      print -r -- "$busy" | cut -c1-200 | sed 's/^/    /'
    fi
    if (( waited >= max )); then
      log "gave up after ${max}s; set WAIT_FOREIGN=0 to run alongside it"
      return 75
    fi
    sleep 10; (( waited += 10 ))
  done
}

# mkdir is atomic: the first job to create $HF/lock owns it. A lock whose
# owner is gone is taken over.
acquire_lock() {
  local waited=0 owner
  mkdir -p $HF
  while ! mkdir $HF/lock 2>/dev/null; do
    owner=$(cat $HF/lock/pid 2>/dev/null)
    if [[ -n $owner ]] && ! kill -0 $owner 2>/dev/null; then
      log "taking over a stale lock from pid $owner"
      mkdir -p $HF/trash
      mv $HF/lock $HF/trash/lock-stale-$(date +%Y%m%d_%H%M%S)-$owner
      continue
    fi
    (( waited % 60 == 0 )) && log "waiting for the happy-fast lock (pid ${owner:-?}: $(cat $HF/lock/what 2>/dev/null))"
    sleep 5; (( waited += 5 ))
  done
  print -r -- $$ > $HF/lock/pid
  print -r -- "$1" > $HF/lock/what
  LOCK_HELD=1
}

release_lock() {
  [[ ${LOCK_HELD:-0} == 1 ]] || return 0
  # Only our own lock; the trash rule does not apply to this empty marker dir.
  [[ $(cat $HF/lock/pid 2>/dev/null) == $$ ]] && /bin/rm -f $HF/lock/pid $HF/lock/what && rmdir $HF/lock
  LOCK_HELD=0
}

# The pool of simulators this tooling owns: happy-fast-1..N, iPhone 17 Pro.
# Created once and reused; never the simulators other jobs use.
sim_ids() {
  local n=$1 i id
  for i in $(seq 1 $n); do
    id=$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json,sys
name=sys.argv[1]
for rt,devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["name"]==name and d.get("isAvailable",True):
            print(d["udid"]); sys.exit()' "$SIM_PREFIX-$i")
    if [[ -z $id ]]; then
      id=$(xcrun simctl create "$SIM_PREFIX-$i" $SIM_TYPE $SIM_RUNTIME) || return 1
    fi
    print -r -- $id
  done
}

# Boot and wait; already-booted simulators return at once.
boot_sim() { xcrun simctl bootstatus $1 -b > /dev/null 2>&1; }

# Regenerate the Xcode project only when the spec or file list changed.
gen_project() {
  local p=$1 cache=$2
  [[ -d $p/Happy.xcodeproj ]] || rm -f $cache
  (cd $p && xcodegen generate --use-cache --cache-path $cache)
}

# Seed a new DerivedData's SwiftPM checkouts from an existing one (APFS clone,
# no download) so a first build does not resolve packages from the network.
seed_packages() {
  local dd=$1 src
  [[ -d $dd/SourcePackages/checkouts ]] && return 0
  for src in $HF/dd/*/SourcePackages(N) ~/happy-phone-build/20261101_221505/dd/SourcePackages(N); do
    if [[ -d $src/checkouts ]]; then mkdir -p $dd && cp -cR $src $dd/SourcePackages && return 0; fi
  done
}

# Compilation caching (CACHE=1). Measured on this project before it was made
# opt-in; see the prep-pro skill for the numbers.
cache_settings() {
  if [[ ${CACHE:-0} == 1 ]]; then
    print -r -- "COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH=$HF/cas"
  fi
}

# CLEAN=1: move the DerivedData aside (never delete) so the build starts cold.
maybe_clean() {
  local dd=$1
  if [[ ${CLEAN:-0} == 1 && -d $dd ]]; then
    mkdir -p $HF/trash
    local t=$HF/trash/$(date +%Y%m%d_%H%M%S)_clean_$(basename $dd)
    log "CLEAN=1: moving $dd to $t"
    mv $dd $t
  fi
}
