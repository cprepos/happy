#!/usr/bin/env bash
# Puts the gateway client on a Mac: client/ and identity/ under ~/.local/share/browser-stack,
# and that Mac's key (~/.config/browser-stack/gateway-keys/<mac> here) as
# ~/.config/browser-stack/gateway-key there, mode 600. Setup only: nothing it installs
# uses ssh at run time. Whatever it replaces goes to ~/happy-trash/<ts>_browser-stack/ on
# the Mac first. The key never appears on a command line or in the output.
#   gateway/mac-install.sh <mac>          e.g. prep-air
set -euo pipefail
host=${1:?usage: mac-install.sh <mac>}
case "$host" in *[!A-Za-z0-9.-]*|"") echo "bad host: $host" >&2; exit 2;; esac
here=$(cd "$(dirname "$0")/.." && pwd)
key="$HOME/.config/browser-stack/gateway-keys/$host"
[ -f "$key" ] || { echo "no key for $host at $key (make gateway-keys)" >&2; exit 1; }
[ "$(stat -c %a "$key")" = 600 ] || { echo "$key is not mode 600" >&2; exit 1; }
ts=$(date +%Y%m%d_%H%M%S)
ssh_=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "$host")

# The files, as a tar on stdin (no tests). Old copies are moved to the Mac's trash.
tar -C "$here" -cf - --exclude=test client identity | "${ssh_[@]}" "set -e
  d=\$HOME/.local/share/browser-stack; t=\$HOME/happy-trash/${ts}_browser-stack
  new=\$(mktemp -d \$HOME/.local/share/.browser-stack.XXXXXX); tar -C \"\$new\" -xf -
  mkdir -p \"\$d\"
  for p in client identity; do
    if [ -e \"\$d/\$p\" ]; then
      if diff -rq \"\$d/\$p\" \"\$new/\$p\" >/dev/null 2>&1; then continue; fi
      mkdir -p \"\$t\"; mv \"\$d/\$p\" \"\$t/\$p\"; echo \"$host: old \$p moved to \$t\"
    fi
    mv \"\$new/\$p\" \"\$d/\$p\"; echo \"$host: installed \$d/\$p\"
  done
  rmdir \"\$new\" 2>/dev/null || { mkdir -p \"\$t\"; mv \"\$new\" \"\$t/unchanged-copy\"; }"

# The key, on stdin, written with umask 077. It is sent only when the Mac's copy differs
# (compared by sha256; the hash of a random key gives nothing away); a different one goes
# to the trash first.
want=$(sha256sum < "$key" | cut -c1-64)
have=$("${ssh_[@]}" 'k=$HOME/.config/browser-stack/gateway-key; [ -f "$k" ] && shasum -a 256 < "$k" | cut -c1-64 || true')
if [ "$have" = "$want" ]; then
  "${ssh_[@]}" 'chmod 600 $HOME/.config/browser-stack/gateway-key'; echo "$host: key unchanged"
else
  "${ssh_[@]}" "set -e; umask 077
    k=\$HOME/.config/browser-stack/gateway-key; t=\$HOME/happy-trash/${ts}_browser-stack
    mkdir -p \$HOME/.config/browser-stack; tmp=\$(mktemp \$HOME/.config/browser-stack/.key.XXXXXX)
    cat > \"\$tmp\"; chmod 600 \"\$tmp\"
    if [ -f \"\$k\" ]; then mkdir -p \"\$t\"; mv \"\$k\" \"\$t/gateway-key\"; echo \"$host: old key moved to \$t\"; fi
    mv \"\$tmp\" \"\$k\"; echo \"$host: key installed (mode 600)\"" < "$key"
fi
