#!/usr/bin/env bash
# Prints one top-level item (fn, enum, struct or static) of a Rust file read on
# stdin: from the line that declares NAME to the first closing `}` (or `;` for
# a one-line static) at column 0. Used to hash the upstream originals of the
# helpers src/addons copies.
set -euo pipefail
name="$1"
awk -v name="$name" '
  !on && $0 ~ "^(pub(\\([a-z]+\\))? )?(async )?(fn|enum|struct|static) " name "[^A-Za-z0-9_]" { on = 1 }
  on { print; if ($0 ~ /^}/ || ($0 ~ /^(pub(\([a-z]+\))? )?static / && $0 ~ /;$/)) exit }
'
