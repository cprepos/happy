#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted scripts run inside the containers
# Backups of the vault and the secret filler, run through make (selfhost/vault.mk) from
# prep's cron. No sudo: every step that touches backup data runs in prep's Docker as the
# data's own uid, with no network, a read-only root and no capabilities.
#
# Locations (both exist, uid 1991, 0711; each has filler/ as uid 1990, 0700):
#   primary  /girth/backup/vault (ZFS girth/backup/vault; VAULT_BACKUP_DIR), snapshotted as
#            girth/backup/vault@vault-<ts> after every backup
#   mirrors  /mnt/ai-data/backups/happy-vault (ext4; VAULT_BACKUP_MIRRORS, space-separated)
# Vault tarballs are written as 1991 into <dir>/, filler tarballs as 1990 into <dir>/filler/,
# so uid 1991 (Vaultwarden) never reads the filler's credentials. Every tarball has a
# .sha256 next to it. In each location the newest 30 (VAULT_BACKUP_KEEP) of each kind stay;
# older ones move to its retired/. Nothing is ever deleted, and nothing is written under
# /home/prep (rsa_key.pem signs login tokens; the filler tarball holds the agent's vault
# credentials).
#
# vault-backup.sh backup   vault-<UTC ts>.tar.gz: an online SQLite snapshot of the running
#     `vaultwarden` container (vaultwarden backup) as db.sqlite3, plus attachments/, sends/,
#     config.json and rsa_key* from the volume vaultwarden-data, and vaultwarden.env and
#     env-backups/ from vaultwarden-config. Then filler/filler-<ts>.tar.gz: secrets/,
#     state/, policy.json, policy-backups/, audit/ and trash/ of /srv/happy-filler
#     (FILLER_ROOT), read through a read-only bind as uid 1990 (not releases/, current,
#     pipe-bin/, inbox/ or outbox/). Then the primary's ZFS snapshot, then the mirror step.
# vault-backup.sh mirror   copy every tarball of the primary (and its retired/) that a
#     mirror does not have yet into each mirror, checking its sha256 after the copy. A
#     mirror on ZFS gets a snapshot <dataset>@vault-<ts> after a run that copied something.
#     A missing or unwritable mirror, a hash mismatch or a refused snapshot is reported
#     loudly; the other mirrors still run and the exit status is non-zero.
# vault-backup.sh check    restore the newest vault tarball of every location into a
#     throwaway container (tmpfs, no network), report integrity and the counts of users,
#     organizations and ciphers, and check that the newest tarball and its sha256 are the
#     same everywhere; the newest filler tarball likewise (its sha256, that it lists
#     secrets/, the same everywhere), as uid 1990.
# vault-backup.sh status   newest tarball per location and its age; flags a location older
#     than VAULT_BACKUP_STALE_HOURS (26) or missing.
# vault-backup.sh restore <vault-ts.tar.gz | /abs/path/vault-ts.tar.gz>
#     check the tarball against its .sha256, stop the container vaultwarden, move the
#     current contents of vaultwarden-data into <primary>/before-restore-<ts>/ (kept, never
#     deleted), unpack the tarball into vaultwarden-data (vaultwarden.env and env-backups/
#     are left out; vaultwarden-config is not touched), start vaultwarden and wait for
#     /alive. A bare name is looked up in the primary and its retired/; a path is a
#     mirror's (or a ZFS snapshot's) copy. The filler is restored by hand from its tarball.
set -euo pipefail
# cron's PATH has no /usr/sbin (zfs).
PATH="$PATH:/usr/sbin:/sbin"

VUID="${VAULT_UID:-1991}"
FUID="${FILLER_UID:-1990}"
FGID="${FILLER_GID:-1990}"
NAME=vaultwarden
DATA_VOLUME=vaultwarden-data
CONFIG_VOLUME=vaultwarden-config
FILLER_SRC="${FILLER_ROOT:-/srv/happy-filler}"
BACKUPS="${VAULT_BACKUP_DIR:-/girth/backup/vault}"
read -r -a MIRRORS <<<"${VAULT_BACKUP_MIRRORS-/mnt/ai-data/backups/happy-vault}"
KEEP="${VAULT_BACKUP_KEEP:-30}"
VAULT_URL="${VAULT_URL:-http://127.0.0.1:8222}"
RUN=(docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true)
NODE_IMAGE="node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914"

die() { echo "vault-backup: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run as your own account, not root (no sudo needed)"
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "bad VAULT_BACKUP_KEEP $KEEP"
for d in "$BACKUPS" "${MIRRORS[@]}" "$FILLER_SRC"; do
  [[ "$d" == /* && "$d" != *..* ]] || die "not an absolute path: $d"
done
# The image the running container was created from (pinned in vaultwarden.sh).
IMAGE="$(docker inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null)" \
  || die "no container $NAME (make vault-up)"

# --mount (not -v) so docker never creates a missing source directory as root.
bind() { echo "type=bind,src=$1,dst=$2${3:+,readonly}"; }

loud() {
  {
    echo "################################################################"
    echo "vault-backup: FAILED: $*"
    echo "################################################################"
  } >&2
}

# Every tarball gets a .sha256 (older ones too, once); the newest $KEEP $PFX-* stay in
# /backups, older ones move to /backups/retired/, never deleted.
RETIRE_SH='
  mkdir -p -m 700 /backups/retired
  for f in /backups/"$PFX"-*.tar.gz /backups/retired/"$PFX"-*.tar.gz; do
    if [ -f "$f" ] && [ ! -e "$f.sha256" ]; then (cd "${f%/*}" && sha256sum "${f##*/}" >"${f##*/}.sha256"); fi
  done
  n=0
  for f in $(ls -1 /backups/ | grep -E "^$PFX-[0-9]{8}T[0-9]{6}Z\.tar\.gz\$" | sort -r); do
    n=$((n + 1))
    if [ "$n" -gt "$KEEP" ]; then
      mv "/backups/$f" /backups/retired/
      if [ -e "/backups/$f.sha256" ]; then mv "/backups/$f.sha256" /backups/retired/; fi
    fi
  done
'

# Copies missing $PFX-* tarballs into one mirror (inside the container: /src = the
# primary, read-only; /backups = the mirror), then retires its older ones. Prints
# copied=<n> last.
MIRROR_SH='
  set -u
  umask 077
  if [ ! -w /backups ] || [ ! -x /backups ]; then echo "not writable by uid $(id -u)"; exit 3; fi
  copied=0; bad=0
  for f in /src/"$PFX"-*.tar.gz /src/retired/"$PFX"-*.tar.gz; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    { [ -e "/backups/$b" ] || [ -e "/backups/retired/$b" ]; } && continue
    want="$(cut -d" " -f1 "$f.sha256" 2>/dev/null || true)"
    [ -n "$want" ] || want="$(sha256sum "$f" | cut -d" " -f1)"
    if ! cp "$f" "/backups/.part-$b"; then echo "copy of $b failed"; bad=$((bad + 1)); continue; fi
    got="$(sha256sum "/backups/.part-$b" | cut -d" " -f1)"
    if [ "$got" != "$want" ]; then
      echo "$b: sha256 mismatch after copy (want $want, got $got); left as .part-$b"
      bad=$((bad + 1)); continue
    fi
    printf "%s  %s\n" "$got" "$b" >"/backups/$b.sha256"
    mv "/backups/.part-$b" "/backups/$b"
    copied=$((copied + 1))
  done
'"$RETIRE_SH"'
  echo "copied=$copied"
  [ "$bad" -eq 0 ]'

# zfs_snap <dir> <name>: snapshot the ZFS dataset holding <dir>; a no-op elsewhere.
zfs_snap() {
  local dir="$1" snap="$2" fstype ds out
  fstype="$(findmnt -no FSTYPE -T "$dir" 2>/dev/null || true)"
  [[ "$fstype" == zfs ]] || return 0
  ds="$(findmnt -no SOURCE -T "$dir")"
  if out="$(zfs snapshot "$ds@$snap" 2>&1)"; then
    echo "vault-backup: snapshot $ds@$snap"
  else
    loud "$dir: zfs snapshot $ds@$snap refused: $out (one-time: sudo zfs allow -u $(id -un) snapshot,mount ${ds%/*})"
    return 1
  fi
}

# mirror_one <mirror dir> <ts> <uid> <primary dir> <prefix>
mirror_one() {
  local dst="$1" ts="$2" uid="$3" src="$4" pfx="$5" out rc=0 copied
  if [[ ! -d "$dst" ]]; then loud "$dst does not exist"; return 1; fi
  out="$("${RUN[@]}" -u "$uid:$uid" -e PFX="$pfx" -e KEEP="$KEEP" \
    --mount "$(bind "$src" /src ro)" --mount "$(bind "$dst" /backups)" \
    --entrypoint sh "$IMAGE" -c "$MIRROR_SH" 2>&1)" || rc=$?
  copied="$(sed -n 's/^copied=//p' <<<"$out" | tail -n1)"
  if [[ $rc -ne 0 ]]; then
    loud "mirror $dst: $(grep -v '^copied=' <<<"$out" | tr '\n' ' ')"; return 1
  fi
  echo "vault-backup: mirror $dst: ${copied:-0} copied"
  [[ "${copied:-0}" -gt 0 ]] || return 0
  zfs_snap "$dst" "$pfx-$ts"
}

mirror_all() {
  local ts="$1" failed=() d
  for d in "${MIRRORS[@]}"; do
    mirror_one "$d" "$ts" "$VUID" "$BACKUPS" vault || failed+=("$d")
    mirror_one "$d/filler" "$ts" "$FUID" "$BACKUPS/filler" filler || failed+=("$d/filler")
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "vault-backup: ${#failed[@]} mirror(s) FAILED: ${failed[*]}" >&2; return 1
  fi
}

case "${1:-}" in
  backup)
    [[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" == true ]] \
      || die "the container $NAME is not running (make vault-up)"
    [[ -d "$BACKUPS" && -d "$BACKUPS/filler" ]] || die "$BACKUPS or $BACKUPS/filler does not exist"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    rc=0
    docker exec "$NAME" /vaultwarden backup >/dev/null
    "${RUN[@]}" -u "$VUID:$VUID" \
      --mount "type=volume,src=$DATA_VOLUME,dst=/data" --mount "$(bind "$BACKUPS" /backups)" \
      --mount "type=volume,src=$CONFIG_VOLUME,dst=/config,readonly" \
      --tmpfs "/stage:uid=$VUID,gid=$VUID,mode=0700" \
      -e TS="$ts" -e KEEP="$KEEP" -e PFX=vault --entrypoint sh "$IMAGE" -c '
        set -eu
        umask 077
        # The snapshot vaultwarden backup just wrote moves out of /data into the tmpfs stage.
        snap="$(ls -1t /data/db_*.sqlite3 | head -n1)"
        stage=/stage
        mv "$snap" "$stage/db.sqlite3"
        set -- db.sqlite3
        for f in attachments sends config.json rsa_key.pem rsa_key.pub.pem rsa_key.der rsa_key.pub.der; do
          if [ -e "/data/$f" ]; then cp -a "/data/$f" "$stage/"; set -- "$@" "$f"; fi
        done
        for f in vaultwarden.env env-backups; do
          if [ -e "/config/$f" ]; then cp -a "/config/$f" "$stage/"; set -- "$@" "$f"; fi
        done
        tar czf "/backups/.part-vault-$TS.tar.gz" -C "$stage" "$@"
        mv "/backups/.part-vault-$TS.tar.gz" "/backups/vault-$TS.tar.gz"
        echo "vault-backup: vault-$TS.tar.gz ($*)"
'"$RETIRE_SH" || { loud "vault tarball"; rc=1; }
    "${RUN[@]}" -u "$FUID:$FGID" --mount "$(bind "$FILLER_SRC" /f ro)" \
      --mount "$(bind "$BACKUPS/filler" /backups)" -e TS="$ts" -e KEEP="$KEEP" -e PFX=filler \
      --entrypoint sh "$IMAGE" -c '
        set -eu
        umask 077
        cd /f
        set --
        for p in secrets state policy.json policy-backups audit trash; do [ -e "$p" ] && set -- "$@" "$p"; done
        [ -e secrets ] || { echo "no secrets/ under the filler root"; exit 1; }
        tar czf "/backups/.part-filler-$TS.tar.gz" "$@"
        mv "/backups/.part-filler-$TS.tar.gz" "/backups/filler-$TS.tar.gz"
        echo "vault-backup: filler/filler-$TS.tar.gz ($*)"
'"$RETIRE_SH" || { loud "filler tarball"; rc=1; }
    zfs_snap "$BACKUPS" "vault-$ts" || rc=1
    mirror_all "$ts" || rc=1
    exit "$rc"
    ;;
  mirror)
    mirror_all "$(date -u +%Y%m%dT%H%M%SZ)"
    ;;
  check)
    # Every location is mounted read-only at /loc/<i>; a missing one fails.
    mounts=() names=() missing=0 i=0
    for d in "$BACKUPS" "${MIRRORS[@]}"; do
      if [[ -d "$d" ]]; then mounts+=(--mount "$(bind "$d" "/loc/$i" ro)"); names+=("$i=$d")
      else echo "vault-restore-check: FAIL $d: does not exist"; missing=1; fi
      i=$((i + 1))
    done
    rc=0
    "${RUN[@]}" -u "$VUID:$VUID" --tmpfs "/restore:uid=$VUID,gid=$VUID,mode=0700" \
      "${mounts[@]}" -e LOCS="${names[*]}" --entrypoint node "$NODE_IMAGE" --no-warnings -e '
        const fs = require("node:fs"), crypto = require("node:crypto"), { execFileSync } = require("node:child_process");
        const { DatabaseSync } = require("node:sqlite");
        const locs = process.env.LOCS.split(" ").filter(Boolean).map((s) => { const i = s.indexOf("="); return { id: s.slice(0, i), path: s.slice(i + 1) }; });
        let failed = false; const seen = [];
        for (const { id, path } of locs) {
          const dir = "/loc/" + id;
          try {
            const all = fs.readdirSync(dir).filter((f) => /^vault-\d{8}T\d{6}Z\.tar\.gz$/.test(f)).sort();
            if (!all.length) throw new Error("no backups yet");
            const latest = all[all.length - 1];
            const sha = crypto.createHash("sha256").update(fs.readFileSync(dir + "/" + latest)).digest("hex");
            let side = "no .sha256";
            if (fs.existsSync(dir + "/" + latest + ".sha256")) {
              side = fs.readFileSync(dir + "/" + latest + ".sha256", "utf8").split(/\s+/)[0] === sha ? "sha256 ok" : "SHA256 MISMATCH";
            }
            if (side !== "sha256 ok") failed = true;
            const out = "/restore/" + id; fs.mkdirSync(out);
            execFileSync("tar", ["xzf", dir + "/" + latest, "-C", out]);
            const db = new DatabaseSync(out + "/db.sqlite3", { readOnly: true });
            const n = (t) => db.prepare("SELECT count(*) AS n FROM " + t).get().n;
            const ok = Object.values(db.prepare("PRAGMA integrity_check").get())[0];
            if (ok !== "ok") failed = true;
            const rsa = fs.existsSync(out + "/rsa_key.pem");
            if (!rsa) failed = true;
            seen.push({ path, latest, sha });
            console.log(`vault-restore-check: ${path}/${latest}: integrity ${ok}, ${side}, users ${n("users")}, organizations ${n("organizations")}, ciphers ${n("ciphers")}, rsa_key ${rsa ? "present" : "MISSING"}`);
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
    # The filler tarballs, as uid 1990: <dir>/filler/ is not readable by 1991.
    mounts=() names=() i=0
    for d in "$BACKUPS/filler" "${MIRRORS[@]/%//filler}"; do
      if [[ -d "$d" ]]; then mounts+=(--mount "$(bind "$d" "/loc/$i" ro)"); names+=("$i=$d")
      else echo "vault-restore-check: FAIL $d: does not exist"; missing=1; fi
      i=$((i + 1))
    done
    "${RUN[@]}" -u "$FUID:$FGID" "${mounts[@]}" -e LOCS="${names[*]}" --entrypoint sh "$IMAGE" -c '
      bad=0 first=""
      for l in $LOCS; do
        path="${l#*=}" dir="/loc/${l%%=*}"
        latest="$(ls -1 "$dir" | grep -E "^filler-[0-9]{8}T[0-9]{6}Z\.tar\.gz$" | sort | tail -n1)"
        if [ -z "$latest" ]; then echo "vault-restore-check: FAIL $path: no filler backups yet"; bad=1; continue; fi
        sha="$(sha256sum "$dir/$latest" | cut -d" " -f1)"
        side="no .sha256"
        if [ -e "$dir/$latest.sha256" ] && [ "$(cut -d" " -f1 "$dir/$latest.sha256")" = "$sha" ]; then side="sha256 ok"; else bad=1; [ -e "$dir/$latest.sha256" ] && side="SHA256 MISMATCH"; fi
        n="$(tar tzf "$dir/$latest" 2>/dev/null | grep -c "^secrets/." || true)"
        [ "$n" -gt 0 ] || bad=1
        echo "vault-restore-check: $path/$latest: $side, secrets/ entries $n"
        if [ -z "$first" ]; then first="$latest $sha"
        elif [ "$first" != "$latest $sha" ]; then echo "vault-restore-check: FAIL $path: newest filler tarball differs from the primary"; bad=1; fi
      done
      exit "$bad"' || rc=1
    [[ $missing -eq 0 && $rc -eq 0 ]] || { loud "check (see above)"; exit 1; }
    echo "vault-restore-check: all locations ok"
    ;;
  status)
    stale_h="${VAULT_BACKUP_STALE_HOURS:-26}" now="$(date -u +%s)" stale=0
    # status_loc <location> <uid> <prefix>
    status_loc() {
      local d="$1" uid="$2" pfx="$3" newest t age_h flag
      if [[ ! -d "$d" ]]; then printf '  %-45s MISSING\n' "$d"; stale=1; return; fi
      newest="$("${RUN[@]}" -u "$uid:$uid" --mount "$(bind "$d" /b ro)" -e PFX="$pfx" --entrypoint sh "$IMAGE" \
        -c 'ls -1 /b 2>/dev/null | grep -E "^$PFX-[0-9]{8}T[0-9]{6}Z\.tar\.gz$" | sort | tail -n1' 2>/dev/null || true)"
      if [[ -z "$newest" ]]; then printf '  %-45s none (or not readable by uid %s)  STALE\n' "$d" "$uid"; stale=1; return; fi
      t="${newest#"$pfx"-}"; t="${t%Z.tar.gz}"
      age_h=$(( (now - $(date -u -d "${t:0:8} ${t:9:2}:${t:11:2}:${t:13:2}" +%s)) / 3600 ))
      flag=""; if [[ $age_h -ge $stale_h ]]; then flag="  STALE (older than ${stale_h}h)"; stale=1; fi
      printf '  %-45s %s (%sh ago)%s\n' "$d" "$newest" "$age_h" "$flag"
    }
    echo "vault backups (newest per location):"
    for d in "$BACKUPS" "${MIRRORS[@]}"; do status_loc "$d" "$VUID" vault; done
    for d in "$BACKUPS/filler" "${MIRRORS[@]/%//filler}"; do status_loc "$d" "$FUID" filler; done
    ds="$(findmnt -no SOURCE -T "$BACKUPS" 2>/dev/null || true)"
    if [[ "$(findmnt -no FSTYPE -T "$BACKUPS" 2>/dev/null)" == zfs ]]; then
      echo "newest snapshot: $(zfs list -H -t snapshot -o name -s creation "$ds" 2>/dev/null | tail -n1)"
    fi
    exit "$stale"
    ;;
  restore)
    t="${2:-}"
    [[ "$t" =~ (^|/)vault-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ && "$t" != *..* ]] \
      || { echo "usage: vault-backup.sh restore vault-<ts>.tar.gz | /path/to/vault-<ts>.tar.gz" >&2; exit 2; }
    if [[ "$t" == /* ]]; then src=(--mount "$(bind "$(dirname "$t")" /t ro)"); else src=(); fi
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    # Checked before anything stops: a bad or missing tarball changes nothing.
    "${RUN[@]}" -u "$VUID:$VUID" --mount "$(bind "$BACKUPS" /b ro)" "${src[@]}" -e NAME="${t##*/}" -e ABS="${t%%[!/]*}" \
      --entrypoint sh "$IMAGE" -c '
        set -eu
        if [ -n "$ABS" ]; then d=/t; elif [ -f "/b/$NAME" ]; then d=/b; else d=/b/retired; fi
        cd "$d"; sha256sum -c "$NAME.sha256" >/dev/null
        tar tzf "$NAME" | grep -qx db.sqlite3
        echo "vault-restore: $NAME: sha256 ok"'
    echo "vault-restore: stopping $NAME"
    docker stop "$NAME" >/dev/null
    "${RUN[@]}" -u "$VUID:$VUID" --mount "$(bind "$BACKUPS" /b)" --mount "type=volume,src=$DATA_VOLUME,dst=/vd" "${src[@]}" \
      -e NAME="${t##*/}" -e ABS="${t%%[!/]*}" -e TS="$ts" --entrypoint sh "$IMAGE" -c '
        set -eu
        if [ -n "$ABS" ]; then d=/t; elif [ -f "/b/$NAME" ]; then d=/b; else d=/b/retired; fi
        aside="/b/before-restore-$TS"; mkdir -m 700 "$aside"
        for e in $(ls -A /vd); do mv "/vd/$e" "$aside/"; done
        tar xzf "$d/$NAME" -C /vd --exclude vaultwarden.env --exclude env-backups
        echo "vault-restore: $NAME unpacked; the data it replaced is in before-restore-$TS/"' \
      || { loud "restore did not finish; $NAME is stopped; the data it had is in $BACKUPS/before-restore-$ts/"; exit 1; }
    docker start "$NAME" >/dev/null
    for _ in $(seq 1 60); do
      if curl -fs --max-time 2 -o /dev/null "$VAULT_URL/alive"; then echo "vault-restore: $NAME is up"; exit 0; fi
      sleep 1
    done
    loud "$NAME did not answer $VAULT_URL/alive within 60 s (make vault-logs)"; exit 1
    ;;
  *) echo "usage: vault-backup.sh backup|mirror|check|status|restore <tarball>" >&2; exit 2 ;;
esac
