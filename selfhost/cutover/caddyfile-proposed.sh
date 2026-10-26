#!/usr/bin/env bash
# Writes Caddyfile.proposed (next to this script) from the live Caddyfile with every public path
# to LiveKit removed, and prints the diff. Read-only on the live file.
#
#   bash selfhost/cutover/caddyfile-proposed.sh [/home/prep/caddy/Caddyfile]
#
# Removes:
#   1. the `handle /livekit*` block on girthbass.duckdns.org (websocket proxy to 127.0.0.1:7880 plus
#      the retired convai "Voice UI" Next.js page on 127.0.0.1:3000);
#   2. the `livekit.girthbass.duckdns.org` site.
# Caddyfile.proposed is gitignored: the Caddyfile holds bearer tokens and password hashes.
# Caddyfile.diff (committed) is the zero-context diff, which carries no secrets.
set -euo pipefail
SRC=${1:-/home/prep/caddy/Caddyfile}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/Caddyfile.proposed
python3 -I - "$SRC" "$OUT" <<'PY'
import re, sys
src_path, out_path = sys.argv[1], sys.argv[2]
s = open(src_path).read()

def remove_block(s, header_re, what):
    """Removes the brace block whose opening line matches header_re, plus the comment lines
    directly above it and one trailing blank line."""
    m = re.search(header_re, s, re.M)
    if not m:
        print(f"note: {what} not found (already removed?)", file=sys.stderr)
        return s
    start = m.start()
    # swallow comment lines immediately above
    lines_before = s[:start].split("\n")[:-1]
    while lines_before and lines_before[-1].strip().startswith("#"):
        lines_before.pop()
    start = len("\n".join(lines_before)) + (1 if lines_before else 0)
    i = s.index("{", m.start())
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                end = j + 1
                break
    else:
        sys.exit(f"unbalanced braces after {what}")
    if s[end:end + 1] == "\n":
        end += 1
    if s[end:end + 1] == "\n":
        end += 1
    return s[:start] + s[end:]

s = remove_block(s, r"^[ \t]+handle /livekit\* \{", "handle /livekit* block")
s = remove_block(s, r"^livekit\.girthbass\.duckdns\.org \{", "livekit.girthbass.duckdns.org site")
s = s.rstrip("\n") + "\n"
for bad in ("handle /livekit", "livekit.girthbass.duckdns.org", "127.0.0.1:7880"):
    if bad in s:
        sys.exit(f"still contains {bad!r}")
open(out_path, "w").write(s)
PY
diff -U0 --label Caddyfile --label Caddyfile.proposed "$SRC" "$OUT" || true
echo "wrote $OUT" >&2
