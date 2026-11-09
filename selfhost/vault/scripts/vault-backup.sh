#!/usr/bin/env bash
# vault-backup.sh backup   one versioned tarball of the running vault:
#     /srv/happy-vault/backups/vault-<UTC ts>.tar.gz holding an online SQLite
#     snapshot (vaultwarden backup) as db.sqlite3, plus attachments/, rsa_key*
#     and config.json when present, with vault-<ts>.tar.gz.sha256 next to it.
#     Done as uid 1991 inside containers, so it needs docker, not sudo. The
#     newest 30 (VAULT_BACKUP_KEEP) stay in backups/; older ones move to
#     backups/retired/ and are never deleted. Then runs the mirror step below.
# vault-backup.sh mirror   copy every tarball in backups/ and backups/retired/
#     that a mirror does not have yet into each mirror (VAULT_BACKUP_MIRRORS,
#     space-separated; default /girth/backup/vault /mnt/ai-data/backups/happy-vault),
#     as uid 1991, 0600, with a .sha256 that is checked after the copy. Mirrors
#     are flat and never pruned. A mirror on ZFS gets a snapshot
#     <dataset>@vault-<ts> after each run that copied something. A missing or
#     unwritable mirror, a hash mismatch or a refused snapshot is reported
#     loudly; the other mirrors still run and the exit status is non-zero.
# vault-backup.sh check    restore the newest tarball of the primary and of
#     every mirror into a throwaway container (tmpfs, no network), count users,
#     organizations, ciphers, and check that the newest tarball and its sha256
#     are the same in every location.
# vault-backup.sh status   newest tarball per location and its age; flags a
#     location older than VAULT_BACKUP_STALE_HOURS (26) or missing.
# Nothing is ever written under /home/prep: rsa_key.pem signs login tokens.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT=/srv/happy-vault
BACKUPS="${VAULT_BACKUP_DIR:-$ROOT/backups}"
read -r -a MIRRORS <<<"${VAULT_BACKUP_MIRRORS-/girth/backup/vault /mnt/ai-data/backups/happy-vault}"
IMAGE="$(awk '/^ *image: vaultwarden\/server:/{print $2; exit}' "$HERE/compose.vault.yml")"
NODE_IMAGE="node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914"

loud() {
  {
    echo "################################################################"
    echo "vault-backup: MIRROR FAILED: $*"
    echo "################################################################"
  } >&2
}

# Copies missing tarballs into one mirror (inside the container: /src = primary
# backups, read-only; /m = the mirror). Prints copied=<n> last.
# shellcheck disable=SC2016  # expands inside the container, not here
MIRROR_SH='
  set -u
  umask 077
  if [ ! -w /m ] || [ ! -x /m ]; then echo "not writable by uid 1991 (make vault-backup-setup)"; exit 3; fi
  copied=0; bad=0
  for f in /src/vault-*.tar.gz /src/retired/vault-*.tar.gz; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    [ -e "/m/$b" ] && continue
    want="$(cut -d" " -f1 "$f.sha256" 2>/dev/null || true)"
    [ -n "$want" ] || want="$(sha256sum "$f" | cut -d" " -f1)"
    if ! cp "$f" "/m/.part-$b"; then echo "copy of $b failed"; bad=$((bad + 1)); continue; fi
    got="$(sha256sum "/m/.part-$b" | cut -d" " -f1)"
    if [ "$got" != "$want" ]; then
      echo "$b: sha256 mismatch after copy (want $want, got $got); left as .part-$b"
      bad=$((bad + 1)); continue
    fi
    printf "%s  %s\n" "$got" "$b" >"/m/$b.sha256"
    mv "/m/.part-$b" "/m/$b"
    copied=$((copied + 1))
  done
  echo "copied=$copied"
  [ "$bad" -eq 0 ]'

# mirror_one <dir> <ts>: returns non-zero (after a loud message) on any failure.
mirror_one() {
  local dst="$1" ts="$2" out rc=0 copied fstype ds
  if [[ ! -d "$dst" ]]; then
    loud "$dst does not exist (one-time setup: make vault-backup-setup)"; return 1
  fi
  # --mount (not -v) so docker never creates a missing source directory as root.
  out="$(docker run --rm --network none -u 1991:1991 \
    --mount "type=bind,src=$BACKUPS,dst=/src,readonly" --mount "type=bind,src=$dst,dst=/m" \
    --entrypoint sh "$IMAGE" -c "$MIRROR_SH" 2>&1)" || rc=$?
  copied="$(sed -n 's/^copied=//p' <<<"$out" | tail -n1)"
  if [[ $rc -ne 0 ]]; then
    loud "$dst: $(grep -v '^copied=' <<<"$out" | tr '\n' ' ')"; return 1
  fi
  echo "vault-backup: mirror $dst: ${copied:-0} copied"
  [[ "${copied:-0}" -gt 0 ]] || return 0
  fstype="$(findmnt -no FSTYPE -T "$dst" 2>/dev/null || true)"
  [[ "$fstype" == zfs ]] || return 0
  ds="$(findmnt -no SOURCE -T "$dst")"
  if out="$(zfs snapshot "$ds@vault-$ts" 2>&1)"; then
    echo "vault-backup: snapshot $ds@vault-$ts"
  else
    loud "$dst: zfs snapshot $ds@vault-$ts refused: $out (one-time: sudo zfs allow -u $(id -un) snapshot,mount girth/backup)"
    return 1
  fi
}

mirror_all() {
  local ts="$1" failed=() d
  for d in "${MIRRORS[@]}"; do mirror_one "$d" "$ts" || failed+=("$d"); done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "vault-backup: ${#failed[@]} mirror(s) FAILED: ${failed[*]}" >&2; return 1
  fi
}

case "${1:-}" in
  backup)
    # Before make vault-init there is nothing to back up; the timer stays quiet.
    [[ -d "$ROOT/data" ]] || { echo "vault-backup: $ROOT not set up yet (make vault-init); skipped"; exit 0; }
    CONTAINER="$(docker compose -p happy-vault -f "$HERE/compose.vault.yml" ps -q vaultwarden 2>/dev/null || true)"
    [[ -n "$CONTAINER" ]] || { echo "vault-backup: vaultwarden is not running (make vault-up)" >&2; exit 1; }
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    docker exec "$CONTAINER" /vaultwarden backup >/dev/null
    docker run --rm --network none -u 1991:1991 \
      -v "$ROOT/data:/data" -v "$BACKUPS:/backups" -e TS="$ts" -e KEEP="${VAULT_BACKUP_KEEP:-30}" --entrypoint sh "$IMAGE" -c '
        set -eu
        snap="$(ls -1t /data/db_*.sqlite3 | head -n1)"
        stage="/backups/.stage-$TS"; mkdir -m 700 "$stage"
        mv "$snap" "$stage/db.sqlite3"
        set -- db.sqlite3
        for f in attachments sends config.json rsa_key.pem rsa_key.pub.pem rsa_key.der rsa_key.pub.der; do
          [ -e "/data/$f" ] && cp -a "/data/$f" "$stage/" && set -- "$@" "$f"
        done
        umask 077
        tar czf "/backups/vault-$TS.tar.gz" -C "$stage" "$@"
        rm -rf "$stage"
        echo "vault-backup: /srv/happy-vault/backups/vault-$TS.tar.gz ($*)"
        # Every tarball gets a .sha256 (older ones too, once); mirrors check against it.
        mkdir -p -m 700 /backups/retired
        for f in /backups/vault-*.tar.gz /backups/retired/vault-*.tar.gz; do
          if [ -f "$f" ] && [ ! -e "$f.sha256" ]; then (cd "${f%/*}" && sha256sum "${f##*/}" >"${f##*/}.sha256"); fi
        done
        # Keep the newest $KEEP in backups/; older ones move to backups/retired/,
        # never deleted (the vault is small; clear retired/ by hand if ever needed).
        n=0
        for f in $(ls -1 /backups/vault-*.tar.gz | sort -r); do
          n=$((n + 1))
          if [ "$n" -gt "$KEEP" ]; then
            mv "$f" /backups/retired/
            if [ -e "$f.sha256" ]; then mv "$f.sha256" /backups/retired/; fi
          fi
        done
        true'
    mirror_all "$ts"
    ;;
  mirror)
    mirror_all "$(date -u +%Y%m%dT%H%M%SZ)"
    ;;
  check)
    # Every location that exists is mounted read-only at /loc/<i>; missing ones fail.
    mounts=() names=() missing=0 i=0
    for d in "$BACKUPS" "${MIRRORS[@]}"; do
      if [[ -d "$d" ]]; then
        mounts+=(--mount "type=bind,src=$d,dst=/loc/$i,readonly"); names+=("$i=$d")
      else
        echo "vault-restore-check: FAIL $d: does not exist (make vault-backup-setup)"; missing=1
      fi
      i=$((i + 1))
    done
    rc=0
    docker run --rm --network none -u 1991:1991 --read-only --tmpfs /restore:uid=1991,gid=1991,mode=0700 \
      "${mounts[@]}" -e LOCS="${names[*]}" --entrypoint node "$NODE_IMAGE" --no-warnings -e '
        const fs = require("node:fs"), crypto = require("node:crypto"), { execFileSync } = require("node:child_process");
        const { DatabaseSync } = require("node:sqlite");
        const locs = process.env.LOCS.split(" ").filter(Boolean).map((s) => { const i = s.indexOf("="); return { id: s.slice(0, i), path: s.slice(i + 1) }; });
        let failed = false; const seen = [];
        for (const { id, path } of locs) {
          const dir = "/loc/" + id;
          try {
            const all = fs.readdirSync(dir).filter((f) => /^vault-.*\.tar\.gz$/.test(f)).sort();
            if (!all.length) throw new Error("no backups yet");
            const latest = all[all.length - 1];
            const sha = crypto.createHash("sha256").update(fs.readFileSync(dir + "/" + latest)).digest("hex");
            let side = "no .sha256";
            if (fs.existsSync(dir + "/" + latest + ".sha256")) {
              side = fs.readFileSync(dir + "/" + latest + ".sha256", "utf8").split(/\s+/)[0] === sha ? "sha256 ok" : "SHA256 MISMATCH";
              if (side !== "sha256 ok") failed = true;
            }
            const out = "/restore/" + id; fs.mkdirSync(out);
            execFileSync("tar", ["xzf", dir + "/" + latest, "-C", out]);
            const db = new DatabaseSync(out + "/db.sqlite3", { readOnly: true });
            const n = (t) => db.prepare("SELECT count(*) AS n FROM " + t).get().n;
            const ok = Object.values(db.prepare("PRAGMA integrity_check").get())[0];
            if (ok !== "ok") failed = true;
            seen.push({ path, latest, sha });
            console.log(`vault-restore-check: ${path}/${latest}: integrity ${ok}, ${side}, users ${n("users")}, organizations ${n("organizations")}, ciphers ${n("ciphers")}, rsa_key ${fs.existsSync(out + "/rsa_key.pem") ? "present" : "MISSING"}`);
          } catch (e) { failed = true; console.log(`vault-restore-check: FAIL ${path}: ${e.message}`); }
        }
        if (seen.length > 1) {
          const [p] = seen;
          let same = true;
          for (const s of seen.slice(1)) {
            if (s.latest !== p.latest || s.sha !== p.sha) { same = false; failed = true; console.log(`vault-restore-check: FAIL ${s.path}: newest is ${s.latest} (${s.sha.slice(0, 12)}), ${p.path} has ${p.latest} (${p.sha.slice(0, 12)})`); }
          }
          if (same) console.log(`vault-restore-check: newest ${p.latest} is identical in ${seen.length} locations (sha256 ${p.sha.slice(0, 12)}...)`);
        }
        process.exit(failed ? 1 : 0);' || rc=$?
    [[ $missing -eq 0 && $rc -eq 0 ]]
    ;;
  status)
    stale_h="${VAULT_BACKUP_STALE_HOURS:-26}" now="$(date -u +%s)"
    for d in "$BACKUPS" "${MIRRORS[@]}"; do
      if [[ ! -d "$d" ]]; then printf '  %-40s MISSING (make vault-backup-setup)\n' "$d"; continue; fi
      newest="$(docker run --rm --network none -u 1991:1991 --mount "type=bind,src=$d,dst=/b,readonly" --entrypoint sh "$IMAGE" \
        -c 'ls -1 /b 2>/dev/null | grep -E "^vault-[0-9]{8}T[0-9]{6}Z\.tar\.gz$" | sort | tail -n1' 2>/dev/null || true)"
      if [[ -z "$newest" ]]; then printf '  %-40s none (or not readable by uid 1991)  STALE\n' "$d"; continue; fi
      t="${newest#vault-}"; t="${t%Z.tar.gz}"
      age_h=$(( (now - $(date -u -d "${t:0:8} ${t:9:2}:${t:11:2}:${t:13:2}" +%s)) / 3600 ))
      flag=""; [[ $age_h -ge $stale_h ]] && flag="  STALE (older than ${stale_h}h)"
      printf '  %-40s %s (%sh ago)%s\n' "$d" "$newest" "$age_h" "$flag"
    done
    ;;
  *) echo "usage: vault-backup.sh backup|mirror|check|status" >&2; exit 2 ;;
esac
