#!/usr/bin/env bash
# vault-backup.sh backup   one versioned tarball of the running vault:
#     /srv/happy-vault/backups/vault-<UTC ts>.tar.gz holding an online SQLite
#     snapshot (vaultwarden backup) as db.sqlite3, plus attachments/, rsa_key*
#     and config.json when present. Done as uid 1991 inside containers, so it
#     needs docker, not sudo. The newest 30 (VAULT_BACKUP_KEEP) stay in
#     backups/; older ones move to backups/retired/ and are never deleted.
# vault-backup.sh check    restore the newest tarball into a throwaway
#     container (tmpfs, no network) and count users, organizations, ciphers.
# Nothing is ever written under /home/prep: rsa_key.pem signs login tokens.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT=/srv/happy-vault
IMAGE="$(awk '/^ *image: vaultwarden\/server:/{print $2; exit}' "$HERE/compose.vault.yml")"
NODE_IMAGE="node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914"
CONTAINER="$(docker compose -p happy-vault -f "$HERE/compose.vault.yml" ps -q vaultwarden 2>/dev/null || true)"

case "${1:-}" in
  backup)
    # Before make vault-init there is nothing to back up; the timer stays quiet.
    [[ -d "$ROOT/data" ]] || { echo "vault-backup: $ROOT not set up yet (make vault-init); skipped"; exit 0; }
    [[ -n "$CONTAINER" ]] || { echo "vault-backup: vaultwarden is not running (make vault-up)" >&2; exit 1; }
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    docker exec "$CONTAINER" /vaultwarden backup >/dev/null
    docker run --rm --network none -u 1991:1991 \
      -v "$ROOT/data:/data" -v "$ROOT/backups:/backups" -e TS="$ts" -e KEEP="${VAULT_BACKUP_KEEP:-30}" --entrypoint sh "$IMAGE" -c '
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
        # Keep the newest $KEEP in backups/; older ones move to backups/retired/,
        # never deleted (the vault is small; clear retired/ by hand if ever needed).
        mkdir -p -m 700 /backups/retired
        n=0
        for f in $(ls -1 /backups/vault-*.tar.gz | sort -r); do
          n=$((n + 1)); [ "$n" -gt "$KEEP" ] && mv "$f" /backups/retired/
        done
        true'
    ;;
  check)
    docker run --rm --network none -u 1991:1991 --read-only --tmpfs /restore:uid=1991,gid=1991,mode=0700 \
      -v "$ROOT/backups:/backups:ro" --entrypoint node "$NODE_IMAGE" --no-warnings -e '
        const fs = require("node:fs"), { execFileSync } = require("node:child_process");
        const all = fs.readdirSync("/backups").filter((f) => /^vault-.*\.tar\.gz$/.test(f)).sort();
        if (!all.length) { console.error("vault-restore-check: no backups yet (make vault-backup)"); process.exit(1); }
        const latest = all[all.length - 1];
        execFileSync("tar", ["xzf", "/backups/" + latest, "-C", "/restore"]);
        const { DatabaseSync } = require("node:sqlite");
        const db = new DatabaseSync("/restore/db.sqlite3", { readOnly: true });
        const n = (t) => db.prepare("SELECT count(*) AS n FROM " + t).get().n;
        const ok = db.prepare("PRAGMA integrity_check").get();
        console.log(`vault-restore-check: ${latest}: integrity ${Object.values(ok)[0]}, users ${n("users")}, organizations ${n("organizations")}, ciphers ${n("ciphers")}, rsa_key ${fs.existsSync("/restore/rsa_key.pem") ? "present" : "MISSING"}`);'
    ;;
  *) echo "usage: vault-backup.sh backup|check" >&2; exit 2 ;;
esac
