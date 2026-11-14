#!/usr/bin/env bash
# Checks that the addons stay a small, mergeable layer over upstream.
#
#   scripts/addons/upstream-check.sh [UPSTREAM]     (default: origin/main)
#
# 1. Every file that exists upstream and that this branch changes must be
#    listed in docs/addons.md (the `touch-points` block) and change no more
#    lines (added + removed) than listed there. Fails otherwise.
# 2. `git merge-tree` of HEAD and UPSTREAM over their merge base must merge
#    cleanly. Fails on a conflict, except in Cargo.lock, which is regenerated
#    (warning only).
# 3. Each `// upstream-copy: <file> <item> <hash>` comment in src/addons names
#    an upstream item the addons copy. The item's text in UPSTREAM is hashed
#    again; a different hash is a warning: upstream changed the original, so
#    the copy should be looked at.
set -euo pipefail

upstream="${1:-${UPSTREAM:-origin/main}}"
crate_dir="$(cd "$(dirname "$0")/../.." && pwd)"
repo="$(git -C "$crate_dir" rev-parse --show-toplevel)"
crate_rel="${crate_dir#"$repo"/}"
doc="$crate_dir/docs/addons.md"
item="$crate_dir/scripts/addons/upstream-item.sh"

git -C "$repo" rev-parse --verify -q "$upstream^{commit}" >/dev/null \
  || { echo "upstream-check: unknown ref $upstream" >&2; exit 2; }
base="$(git -C "$repo" merge-base HEAD "$upstream")"
fail=0
warn=0

# --- 1. touch points ---------------------------------------------------------
declare -A allowed=()
while read -r path max; do
  [[ -z "$path" || "$path" == \#* ]] && continue
  allowed["$path"]="$max"
done < <(awk '/^```touch-points/{on=1; next} on && /^```/{exit} on' "$doc")
[[ ${#allowed[@]} -gt 0 ]] || { echo "upstream-check: no touch-points block in $doc" >&2; exit 2; }

declare -A seen=()
while IFS=$'\t' read -r added removed path; do
  # Only files upstream has: files the branch adds are the addons' own.
  git -C "$repo" cat-file -e "$base:$path" 2>/dev/null || continue
  seen["$path"]=1
  max="${allowed[$path]:-}"
  n=$(( ${added/-/0} + ${removed/-/0} ))
  if [[ -z "$max" ]]; then
    echo "FAIL  $path: upstream file changed ($n lines) but not listed in docs/addons.md"
    fail=1
  elif [[ "$max" != "*" && "$n" -gt "$max" ]]; then
    echo "FAIL  $path: $n changed lines, docs/addons.md allows $max"
    fail=1
  else
    echo "ok    $path: $n changed lines (allowed $max)"
  fi
done < <(git -C "$repo" diff --numstat "$base" HEAD)
for path in "${!allowed[@]}"; do
  [[ -n "${seen[$path]:-}" ]] || echo "note  $path: listed but unchanged"
done

# --- 2. merge ----------------------------------------------------------------
if [[ "$(git -C "$repo" rev-parse "$base")" == "$(git -C "$repo" rev-parse "$upstream^{commit}")" ]]; then
  echo "ok    merge: $upstream is already in HEAD"
else
  conflicted="$(git -C "$repo" merge-tree "$base" HEAD "$upstream" | awk '
    /^(changed in both|added in both|removed in local|removed in remote)$/ { blk=1; next }
    blk && /^  (base|our|their) / { file=$4; next }
    blk { blk=0 }
    /^\+<<<<<<< \.our$/ && file != "" { print file; file="" }
  ' | sort -u)"
  if [[ -z "$conflicted" ]]; then
    echo "ok    merge: HEAD merges with $upstream without conflicts"
  fi
  while read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$f" == */Cargo.lock ]]; then
      echo "warn  merge: $f conflicts; take upstream's and run \`cargo update -w\`"
      warn=1
    else
      echo "FAIL  merge: $f conflicts with $upstream"
      fail=1
    fi
  done <<<"$conflicted"
fi

# --- 3. copied items ---------------------------------------------------------
while IFS= read -r line; do
  read -r _ _ file name hash <<<"${line#*:*:}"
  src="$crate_rel/$file"
  if ! text="$(git -C "$repo" show "$upstream:$src" 2>/dev/null)"; then
    echo "warn  copy $name: $src is gone in $upstream"
    warn=1
    continue
  fi
  now="$(printf '%s\n' "$text" | "$item" "$name" | sha256sum | cut -c1-16)"
  if [[ "$now" == "$hash" ]]; then
    echo "ok    copy $file $name: unchanged upstream"
  else
    echo "warn  copy $file $name: upstream changed it ($hash -> $now); compare ${line%%:*}"
    warn=1
  fi
done < <(cd "$crate_dir" && grep -rn "// upstream-copy:" src/addons)

if [[ $fail -ne 0 ]]; then
  echo "upstream-check: FAILED"
  exit 1
fi
[[ $warn -ne 0 ]] && echo "upstream-check: passed with warnings" || echo "upstream-check: passed"
