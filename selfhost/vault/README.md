# Vaultwarden

A self-hosted Bitwarden-compatible server on prep-ml for all of your devices:
the phone, prep-air, prep-pro and the browser extensions. The browser agent's
secret filler (`browser-stack/browser/filler`) also reads it, through its own
restricted account. Design: [docs/plan.md](docs/plan.md).

- Its own compose project, `happy-vault` (`compose.vault.yml`), with
  `restart: unless-stopped`. The same project runs the secret filler
  (service `filler`, 127.0.0.1:6091, data in `/srv/happy-filler`); see
  `browser-stack/browser/filler/README.md`. `make stack-up` / `make
  stack-down` (in `selfhost/`) run the vault and then the browser stack. Docker is enabled at boot, so the vault comes back
  after a reboot. No `browser-*` target touches it.
- It listens on `127.0.0.1:8222` only. From outside, the only way in is the
  existing Caddy :443 site **`https://vault.girthbass.duckdns.org`**. Caddy
  answers `/admin` there with 404. No new port is open.
- Data lives in `/srv/happy-vault` (outside `/home/prep`), owned by uid 1991.

## Server setup (once, in order)

This host's settings (domain, agent email, LAN addresses, `/srv` paths, uids)
are in `vault/.env`, which is not committed; start from `.env.example`.
Caddy is a host service: `vault-caddy-apply` fills `caddy-vault.conf` with
`VAULT_DOMAIN` and adds it to `CADDYFILE`.

```
cp vault/.env.example vault/.env                       # then edit it
make vault-init VAULT_OWNER_EMAIL=<your vault email>   # sudo: /srv/happy-vault, /srv/happy-filler + env file
make vault-up                                           # vaultwarden + filler
make vault-caddy-apply                                  # already applied on 2026-11-04
make vault-admin-on                                     # sudo: choose an admin password
```

1. Open `http://127.0.0.1:8222/admin` on prep-ml (a browser on prep-ml or an
   SSH tunnel; never through Caddy). Under **Users**, invite your own email.
2. At `https://vault.girthbass.duckdns.org`, choose **Create account** with
   that email (there is no SMTP, so an invited email can register directly).
   Pick a strong master password.
3. Turn on two-step login for your account: Settings, Security, Two-step
   login, Authenticator app. The vault is reachable from the internet through
   Caddy, so do not skip this.
4. `make vault-admin-off` (sudo). This turns the admin panel off.
5. `make vault-backup-timer`. This starts the nightly backup.

The agent account for the secret filler (no organization: its logins sit in
its own vault) is in `browser-stack/browser/filler/README.md`.

### The env file

`/srv/happy-vault/vaultwarden.env` (root:1991 0640) holds `ORG_CREATION_USERS`
and, while the admin panel is on, `ADMIN_TOKEN`. Compose does not read it:
it is mounted read-only at `/etc/vaultwarden.env`, and Vaultwarden loads it
itself at start (`ENV_FILE`). The values live only inside the Vaultwarden
process, so `docker exec … printenv ADMIN_TOKEN` prints nothing even when the
file is loaded. To check, use `make vault-status` (it reports each key as set
or unset, never the value), or the log line `Using environment file
/etc/vaultwarden.env`. With `ADMIN_TOKEN` unset, `/admin` on 127.0.0.1 shows
"The admin panel is disabled".

## Clients

The server URL is the same everywhere: `https://vault.girthbass.duckdns.org`.

- **iPhone / iPad (Bitwarden app):** on the login screen, tap the region picker
  ("Logging in on"), choose **Self-hosted**, and enter the server URL. There is
  no push (`PUSH_ENABLED=false`), so pull down on the vault list to sync.
- **macOS desktop app (prep-air, prep-pro):** on the login screen, open the
  region menu, choose **Self-hosted**, and enter the server URL.
- **Browser extensions (Safari, Chrome, Firefox):** on the extension's login
  screen, open the region menu, choose **Self-hosted**, and enter the server
  URL.
- Live sync between desktop and extensions works over the websocket at
  `/notifications/hub`, which Caddy passes through.

## Make targets (from `selfhost/`)

```
make vault-status         # health, 127.0.0.1-only bind, public /alive, public /admin = 404, env keys set/unset, timer, newest backup
make vault-up | vault-down | vault-logs
make vault-backup         # one tarball now, then copied to every mirror (+ ZFS snapshot)
make vault-backup-mirror  # copy whatever a mirror is missing, without a new backup
make vault-restore-check  # restore the newest tarball of every location in a throwaway container; counts, sha256 across locations
make vault-backup-timer   # install + enable the nightly systemd user timer
make vault-backup-setup   # print (never run) the one-time sudo commands for mirrors, snapshots, the secrets timer
make vault-admin-on | vault-admin-off   # sudo
```

`make status` (the main health check) runs `vault-status` too.

## Backup and restore

### What runs every night

| When | What | Where |
|------|------|-------|
| 04:15 (+ up to 10m), user timer `happy-vault-backup.timer` | `make vault-backup`: the vault tarball, then the mirror step | primary + every mirror |
| 04:45 (+ up to 5m), root timer `happy-vault-secrets-backup.timer` | filler state + `vaultwarden.env` | `secrets/` in every mirror |

Both timers catch up after downtime (`Persistent=true`). Nothing in either
ever deletes a backup or a snapshot.

**Primary.** `make vault-backup` takes an online SQLite snapshot (`vaultwarden
backup`) and writes `/srv/happy-vault/backups/vault-<UTC timestamp>.tar.gz`
plus `vault-<ts>.tar.gz.sha256`. The tarball holds `db.sqlite3`,
`attachments/`, `rsa_key*` and `config.json`. The newest 30 stay in
`backups/`. Older ones (and their `.sha256`) move to `backups/retired/` and are
never deleted. The primary is on the OS disk.

**Mirrors.** Right after that, every tarball in `backups/` and
`backups/retired/` that a mirror does not have yet is copied into it, so a
mirror that was offline catches up on its next run. Mirrors are flat (no
`retired/`) and never pruned. Defaults (`VAULT_BACKUP_MIRRORS`,
space-separated):

- `/girth/backup/vault`: ZFS dataset `girth/backup/vault` on the raidz pool.
- `/mnt/ai-data/backups/happy-vault`: the separate 4 TB SSD.

The copy runs as uid 1991 in a container (no sudo), files 0600. Each copy is
hashed and compared with the primary's `.sha256` before it gets its own
`.sha256` and its final name (until then it is `.part-<name>`). After a run that
copied something to a mirror on ZFS, the script takes
`girth/backup/vault@vault-<ts>`; snapshots are never destroyed.

If a mirror is missing, not writable by uid 1991, a hash does not match, or
the snapshot is refused, the script prints a `MIRROR FAILED` banner naming the
target, still does the other mirrors, and exits non-zero, so the unit shows
failed (`systemctl --user status happy-vault-backup.service`). The primary
tarball is written first and is kept either way.

**Secrets.** The vault tarball cannot hold what only root can read: the
filler's `/srv/happy-filler/{policy.json,policy-backups,audit,state,secrets}`
and `/srv/happy-vault/{vaultwarden.env,env-backups}`. The root timer runs
`/usr/local/sbin/happy-vault-secrets-backup` (installed from
`scripts/vault-secrets-backup.sh`), which tars whichever of those exist into
`<mirror>/secrets/secrets-<ts>.tar.gz` (root 0600, `secrets/` root 0700) with a
`.sha256`, copies it to every mirror, checks the hash, and takes
`girth/backup/vault@secrets-<ts>`. It prints file names, never contents. The
repo copy is not what runs: after changing the script or its units, run the
install lines again.

`rsa_key.pem` signs login tokens and the secrets tarball holds the filler's
credentials, so nothing is written under `/home/prep`. A vault tarball holds
only data that is already encrypted with your master password, except
`rsa_key.pem`.

### One-time setup (sudo, by you)

`make vault-backup-setup` prints these; nothing runs them automatically.

```
sudo zfs create -p -o compression=lz4 girth/backup/vault
sudo chown 1991:1991 /girth/backup/vault && sudo chmod 700 /girth/backup/vault
sudo mkdir -p /mnt/ai-data/backups/happy-vault
sudo chown 1991:1991 /mnt/ai-data/backups/happy-vault && sudo chmod 700 /mnt/ai-data/backups/happy-vault
sudo zfs allow -u prep snapshot,mount girth/backup
sudo install -o root -g root -m 0755 /home/prep/happy/selfhost/vault/scripts/vault-secrets-backup.sh /usr/local/sbin/happy-vault-secrets-backup
sudo install -o root -g root -m 0644 /home/prep/happy/selfhost/vault/systemd/happy-vault-secrets-backup.service /home/prep/happy/selfhost/vault/systemd/happy-vault-secrets-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now happy-vault-secrets-backup.timer
sudo systemctl start happy-vault-secrets-backup.service
```

`zfs allow` lets prep take snapshots under `girth/backup` (on Linux ZFS
documents `snapshot` as needing `mount` too); it does not allow destroying
anything. Then fill the mirrors with what is already in the primary:

```
make vault-backup-mirror
make vault-restore-check
```

### Checking

```
make vault-restore-check   # safe at any time
make vault-status          # newest tarball per location, flagged STALE past 26h; secrets timer result
```

`vault-restore-check` restores the newest tarball of the primary and of each
mirror into a throwaway container (tmpfs, no network), runs `PRAGMA
integrity_check`, counts users, organizations and ciphers, checks each file
against its `.sha256`, and fails unless every location's newest tarball is
the same file with the same hash. A missing mirror fails the check.

Neither target can see `secrets/` (root only). To check it, use
`systemctl status happy-vault-secrets-backup.service`, or
`sudo sh -c 'cd /girth/backup/vault/secrets && sha256sum -c secrets-*.sha256'`
(the same for `/mnt/ai-data/backups/happy-vault/secrets`).

### Restoring

The vault tarball is the same in every location; pick the one you trust:

| Location | Tarball |
|----------|---------|
| primary | `/srv/happy-vault/backups/vault-<ts>.tar.gz` (older: `backups/retired/`) |
| ZFS mirror | `/girth/backup/vault/vault-<ts>.tar.gz` |
| ZFS snapshot | `/girth/backup/vault/.zfs/snapshot/vault-<ts>/vault-<ts>.tar.gz` (`zfs list -t snapshot girth/backup/vault`) |
| SSD mirror | `/mnt/ai-data/backups/happy-vault/vault-<ts>.tar.gz` |

As root, with `T` set to that path:

```
make vault-down
sudo sh -c 'cd "$(dirname "$1")" && sha256sum -c "$(basename "$1").sha256"' _ "$T"
sudo mv /srv/happy-vault/data /srv/happy-vault/data.before-restore.$(date +%s)
sudo install -d -o 1991 -g 1991 -m 0700 /srv/happy-vault/data
sudo tar xzf "$T" -C /srv/happy-vault/data
sudo chown -R 1991:1991 /srv/happy-vault/data
make vault-up
```

If `/srv/happy-vault/backups` itself is gone (a dead OS disk), recreate it with
`make vault-init` first; the restore is the same.

The secrets tarball holds relative entries (`srv/happy-filler/...`,
`srv/happy-vault/...`). Look before restoring, and restore single paths:

```
sudo tar tzf /girth/backup/vault/secrets/secrets-<ts>.tar.gz
sudo mv /srv/happy-vault/vaultwarden.env /srv/happy-vault/env-backups/vaultwarden.env.before-restore.$(date +%s)
sudo tar xzf /girth/backup/vault/secrets/secrets-<ts>.tar.gz -C / --same-owner -p srv/happy-vault/vaultwarden.env
```

The same works for `srv/happy-filler/policy.json` and the other filler paths
(move the current one aside first; `--same-owner -p` keeps happy-filler as the
owner and the 0700/0600 modes).
