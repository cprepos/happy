#!/usr/bin/env bash
# vault-secrets-backup.sh: the root-only half of the vault backups. Runs as
# root (happy-vault-secrets-backup.service, installed to
# /usr/local/sbin/happy-vault-secrets-backup; see make vault-backup-setup).
#
# Tars what make vault-backup cannot read as uid 1991 or prep:
#   /srv/happy-filler/{policy.json,policy-backups,audit,state,secrets}
#   /srv/happy-vault/{vaultwarden.env,env-backups}
# (whichever exist) into secrets-<UTC ts>.tar.gz (root 0600) plus a .sha256,
# under <mirror>/secrets/ (root:root 0700) for each mirror in
# VAULT_BACKUP_MIRRORS (default /girth/backup/vault /mnt/ai-data/backups/happy-vault).
# The tarball is written once, then copied to the other mirrors and its hash
# checked there. Never prunes. A mirror on ZFS gets a snapshot
# <dataset>@secrets-<ts>. A missing mirror or failed copy is reported loudly,
# the other mirrors still run, and the exit status is non-zero.
# Prints file names only, never contents.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "vault-secrets-backup: run as root (the system timer does)" >&2; exit 1; }
read -r -a MIRRORS <<<"${VAULT_BACKUP_MIRRORS-/girth/backup/vault /mnt/ai-data/backups/happy-vault}"
umask 077
ts="$(date -u +%Y%m%dT%H%M%SZ)"
name="secrets-$ts.tar.gz"

loud() {
  {
    echo "################################################################"
    echo "vault-secrets-backup: FAILED: $*"
    echo "################################################################"
  } >&2
}

paths=()
for p in srv/happy-filler/policy.json srv/happy-filler/policy-backups srv/happy-filler/audit \
         srv/happy-filler/state srv/happy-filler/secrets srv/happy-vault/vaultwarden.env srv/happy-vault/env-backups; do
  [[ -e "/$p" ]] && paths+=("$p")
done
[[ ${#paths[@]} -gt 0 ]] || { loud "nothing to back up under /srv/happy-filler or /srv/happy-vault"; exit 1; }

first="" sha="" failed=()
for m in "${MIRRORS[@]}"; do
  if [[ ! -d "$m" ]]; then loud "$m does not exist (one-time setup: make vault-backup-setup)"; failed+=("$m"); continue; fi
  dir="$m/secrets"
  if ! install -d -o root -g root -m 0700 "$dir"; then loud "$dir: cannot create"; failed+=("$m"); continue; fi
  if [[ -z "$first" ]]; then
    # GNU tar exits 1 when a file changed while it was read (a live audit log);
    # the archive is still complete, so only exit 2 counts as a failure.
    trc=0
    tar --create --gzip --file "$dir/.part-$name" --warning=no-file-changed -C / "${paths[@]}" || trc=$?
    if [[ $trc -gt 1 ]]; then loud "$dir: tar exited $trc"; failed+=("$m"); continue; fi
    sha="$(sha256sum "$dir/.part-$name" | cut -d' ' -f1)"
  else
    if ! cp "$first" "$dir/.part-$name"; then loud "$dir: copy failed"; failed+=("$m"); continue; fi
    got="$(sha256sum "$dir/.part-$name" | cut -d' ' -f1)"
    if [[ "$got" != "$sha" ]]; then loud "$dir: sha256 mismatch after copy; left as .part-$name"; failed+=("$m"); continue; fi
  fi
  printf '%s  %s\n' "$sha" "$name" >"$dir/$name.sha256"
  mv "$dir/.part-$name" "$dir/$name"
  [[ -n "$first" ]] || first="$dir/$name"
  echo "vault-secrets-backup: $dir/$name (${paths[*]})"
  if [[ "$(findmnt -no FSTYPE -T "$dir" 2>/dev/null || true)" == zfs ]]; then
    ds="$(findmnt -no SOURCE -T "$dir")"
    if zfs snapshot "$ds@secrets-$ts"; then echo "vault-secrets-backup: snapshot $ds@secrets-$ts"
    else loud "$m: zfs snapshot $ds@secrets-$ts failed"; failed+=("$m"); fi
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "vault-secrets-backup: ${#failed[@]} mirror(s) FAILED: ${failed[*]}" >&2; exit 1
fi
