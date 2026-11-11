# Vaultwarden

A self-hosted Bitwarden-compatible server on prep-ml for all of your devices:
the phone, prep-air, prep-pro and the browser extensions. The browser agent's
secret filler (`browser-stack/browser/filler`) also reads it, through its own
restricted account. Design: [docs/plan.md](docs/plan.md).

- Its own compose project, `happy-vault` (`compose.vault.yml`), with
  `restart: unless-stopped`. The same project runs the secret filler
  (service `filler`, 127.0.0.1:6091, data in the volume `happy-filler`); see
  `browser-stack/browser/filler/README.md`. `make stack-up` / `make
  stack-down` (in `selfhost/`) run the vault and then the browser stack. Docker is enabled at boot, so the vault comes back
  after a reboot. No `browser-*` target touches it.
- It listens on `127.0.0.1:8222` only. From outside, the only way in is the
  existing Caddy :443 site **`https://vault.girthbass.duckdns.org`**. Caddy
  answers `/admin` there with 404. No new port is open.
- Data lives in named Docker volumes, never under `/home/prep`, and no make
  target needs sudo. `happy-vault-data`, `-config` and `-backups` belong to
  uid 1991 (Vaultwarden). `happy-filler` and `happy-filler-backups` belong
  to uid 1990 (the filler). `make vault-init` creates them. A one-shot root
  container with only `CAP_CHOWN` hands each new volume to its uid; every
  other step runs as the uid itself, with no network and no capabilities.

## Server setup (once, in order)

This host's settings (domain, agent email, LAN addresses, uids)
are in `vault/.env`, which is not committed; start from `.env.example`.
Caddy is a host service: `vault-caddy-apply` fills `caddy-vault.conf` with
`VAULT_DOMAIN` and adds it to `CADDYFILE`.

```
cp vault/.env.example vault/.env                       # then edit it
make vault-init VAULT_OWNER_EMAIL=<your vault email>   # the volumes, the env file, the filler's tree
make vault-up                                           # vaultwarden + filler
make vault-caddy-apply                                  # already applied on 2026-11-04
make vault-admin-on                                     # choose an admin password (asked on the terminal)
```

1. Open `http://127.0.0.1:8222/admin` on prep-ml (a browser on prep-ml or an
   SSH tunnel; never through Caddy). Under **Users**, invite your own email.
2. At `https://vault.girthbass.duckdns.org`, choose **Create account** with
   that email (there is no SMTP, so an invited email can register directly).
   Pick a strong master password.
3. Turn on two-step login for your account: Settings, Security, Two-step
   login, Authenticator app. The vault is reachable from the internet through
   Caddy, so do not skip this.
4. `make vault-admin-off`. This turns the admin panel off.
5. `make vault-backup-timer`. This starts the nightly backup.

The agent account for the secret filler (no organization: its logins sit in
its own vault) is in `browser-stack/browser/filler/README.md`.

### The env file

`vaultwarden.env` in the volume `happy-vault-config` (uid 1991, 0600) holds
`ORG_CREATION_USERS` and, while the admin panel is on, `ADMIN_TOKEN`: only
the argon2 hash of the password, which `make vault-admin-on` asks for on the
terminal. Each edit first copies the file into `env-backups/<ts>` in the same
volume. Compose does not read the file: the volume is mounted read-only at
`/etc/vaultwarden`, and Vaultwarden loads the file
itself at start (`ENV_FILE`). The values live only inside the Vaultwarden
process, so `docker exec … printenv ADMIN_TOKEN` prints nothing even when the
file is loaded. To check, use `make vault-status` (it reports each key as set
or unset, never the value), or the log line `Using environment file
/etc/vaultwarden/vaultwarden.env`. With `ADMIN_TOKEN` unset, `/admin` on 127.0.0.1 shows
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
make vault-backup         # the vault and filler tarballs now, then copied to every mirror (+ ZFS snapshot)
make vault-backup-mirror  # copy whatever a mirror is missing, without a new backup
make vault-restore-check  # restore the newest tarball of every location in a throwaway container; counts, sha256 across locations
make vault-backup-timer   # install + enable the nightly systemd user timer
make vault-restore TARBALL=vault-<ts>.tar.gz   # put a backup back (see Restoring)
make vault-backup-setup   # print (never run) the one-time sudo commands for the mirror dirs and snapshots
make vault-admin-on | vault-admin-off
make vault-migrate-volumes | vault-filler-cutover   # once, an install from before the volumes (see below)
```

`make status` (the main health check) runs `vault-status` too.

## Backup and restore

### What runs every night

The user timer `happy-vault-backup.timer` (04:15, plus up to 10 minutes)
runs `make vault-backup`. It catches up after downtime (`Persistent=true`).
Nothing ever deletes a backup or a snapshot.

**Vault tarball.** An online SQLite snapshot (`vaultwarden backup`) goes into
`vault-<UTC timestamp>.tar.gz` with a `.sha256`, in the volume
`happy-vault-backups`, written as uid 1991. It holds `db.sqlite3`,
`attachments/`, `rsa_key*` and `config.json`. From `happy-vault-config` it
also takes `vaultwarden.env` and `env-backups/`.

**Filler tarball.** `filler-<ts>.tar.gz` with a `.sha256`, in the volume
`happy-filler-backups`, written as uid 1990. It holds the filler's
`policy.json`, `policy-backups/`, `audit/`, `state/` and `secrets/`. It never
goes where uid 1991 can read it. Those are the agent's vault credentials,
and a compromised Vaultwarden must not get them.

In each volume the newest 30 stay. Older tarballs (and their `.sha256`)
move to `retired/` and are never deleted. Both volumes are on the OS disk.

**Mirrors.** Right after that, every tarball a mirror does not have yet is
copied into it, `retired/` included, so a mirror that was offline catches up
on its next run. Mirrors are flat (no `retired/`) and never pruned. Defaults
(`VAULT_BACKUP_MIRRORS`, space-separated):

- `/girth/backup/vault`: ZFS dataset `girth/backup/vault` on the raidz pool.
- `/mnt/ai-data/backups/happy-vault`: the separate 4 TB SSD.

Vault tarballs go into `<mirror>/` as uid 1991, filler tarballs into
`<mirror>/filler/` as uid 1990, all in containers (no sudo), files 0600.
`<mirror>` is 1991's with mode 0711, so 1990 can pass through to its own
`filler/` (0700) without listing the vault tarballs. 1991 cannot open
`filler/`. Each copy is hashed and compared with the primary's `.sha256`
before it gets its own `.sha256` and its final name (until then it is
`.part-<name>`). After a run that copied something to a mirror on ZFS, the
script takes `girth/backup/vault@vault-<ts>` (and `@filler-<ts>`); snapshots
are never destroyed.

If a mirror is missing or not writable, a hash does not match, or a snapshot
is refused, the script prints a `MIRROR FAILED` banner naming the target,
still does the other mirrors, and exits non-zero, so the unit shows failed
(`systemctl --user status happy-vault-backup.service`). The primary tarballs
are written first and kept either way.

### One-time setup (sudo, by you)

`make vault-backup-setup` prints these; nothing runs them automatically.

```
sudo zfs create -p -o compression=lz4 girth/backup/vault
sudo mkdir -p /mnt/ai-data/backups/happy-vault
sudo chown 1991:1991 /girth/backup/vault && sudo chmod 0711 /girth/backup/vault
sudo install -d -o 1990 -g 1990 -m 0700 /girth/backup/vault/filler
sudo chown 1991:1991 /mnt/ai-data/backups/happy-vault && sudo chmod 0711 /mnt/ai-data/backups/happy-vault
sudo install -d -o 1990 -g 1990 -m 0700 /mnt/ai-data/backups/happy-vault/filler
sudo zfs allow -u prep snapshot,mount girth/backup
```

`zfs allow` lets prep take snapshots under `girth/backup` (on Linux ZFS
documents `snapshot` as needing `mount` too); it does not allow destroying
anything. Then fill the mirrors with what is already in the volumes:

```
make vault-backup-mirror
make vault-restore-check
```

### Checking

```
make vault-restore-check   # safe at any time
make vault-status          # newest tarball per location, flagged STALE past 26h
```

`vault-restore-check` restores the newest vault tarball of each location
(the volume and every mirror) into a throwaway container (tmpfs, no network).
It runs `PRAGMA integrity_check`, counts users, organizations and ciphers,
and checks each file against its `.sha256`. It fails unless every location's
newest tarball is the same file with the same hash. Then, as uid 1990, it
does the same for the newest filler tarball: its `.sha256`, that it holds
`secrets/`, and that it is the same everywhere. A missing mirror fails the
check.

### Restoring

The vault tarball is the same in every location; pick the one you trust:

| Location | `TARBALL=` |
|----------|---------|
| the volume | `vault-<ts>.tar.gz` (also finds it in `retired/`) |
| ZFS mirror | `/girth/backup/vault/vault-<ts>.tar.gz` |
| ZFS snapshot | `/girth/backup/vault/.zfs/snapshot/vault-<ts>/vault-<ts>.tar.gz` (`zfs list -t snapshot girth/backup/vault`) |
| SSD mirror | `/mnt/ai-data/backups/happy-vault/vault-<ts>.tar.gz` |

```
make vault-restore TARBALL=...
```

It checks the tarball against its `.sha256` before stopping anything. It then
stops Vaultwarden and moves the current data into
`happy-vault-backups/before-restore-<ts>/`, which is kept. It unpacks the
tarball into `happy-vault-data` and starts Vaultwarden. `vaultwarden.env`
and `env-backups/` in the tarball are left out, and `happy-vault-config` is
not touched. If the volumes themselves are gone (a dead OS disk), run
`make vault-init` first, then restore from a mirror path.

To put back a single file of the env or the filler, look into the tarball
first, as the owning uid. For example, the filler's `policy.json` from the
ZFS mirror (the current one goes to `trash/` in the volume first):

```
IMG=$(awk '/^ *image: vaultwarden\/server:/{print $2; exit}' vault/compose.vault.yml)
docker run --rm --network none -u 1990:1990 -v happy-filler:/f \
  --mount type=bind,src=/girth/backup/vault/filler,dst=/t,readonly --entrypoint sh "$IMG" -c '
  tar tzf /t/filler-<ts>.tar.gz | head
  d=/f/trash/$(date -u +%Y%m%dT%H%M%SZ)-restore; mkdir -p $d; mv /f/policy.json $d/
  tar xzf /t/filler-<ts>.tar.gz -C /f policy.json'
make filler-restart
```

### Moving an install from /srv into the volumes

Before the volumes, the data was in root-made `/srv/happy-vault` and
`/srv/happy-filler` (`VAULT_ROOT`, `FILLER_ROOT` in `.env`). The move takes
two steps, needs no sudo, and never changes `/srv`, which stays as the
rollback.

```
make vault-migrate-volumes
```

This copies `/srv/happy-filler` into `happy-filler` as uid 1990, leaving out
the old unit's `releases/`, `current` and `pipe-bin/`. Modes are kept, and
`audit/`, `outbox/` and `inbox/` are regrouped to 1990. Then it stops
Vaultwarden, copies `data/`, `backups/` and `vaultwarden.env` into its three
volumes as uid 1991, and starts it on them. Last, it checks `/alive` and
the old filler's `healthz` on 6091. The old systemd filler unit keeps
serving 6091 from `/srv` the whole time. Each copy refuses to run twice.

Then, when you are ready to switch the filler over:

```
sudo -u happy-filler XDG_RUNTIME_DIR=/run/user/1990 systemctl --user disable --now happy-filler.service
make vault-filler-cutover
```

The cutover copies again every file of `policy.json`, `state/`, `secrets/`,
`audit/` and `outbox/` that is newer in `/srv` than in the volume (the
volume's older copy goes to `trash/<ts>-cutover/` first), then starts the
filler container. Secrets or policy changed through the old unit after
`vault-migrate-volumes` come across this way.

Rollback: `/srv` still holds the state from the moment of the copy. Anything
saved after that exists only in the volumes. For Vaultwarden, run the
compose file from before the volumes, which binds `/srv/happy-vault/data`:

```
git show e2c43b03f^:selfhost/vault/compose.vault.yml > /tmp/compose.vault.srv.yml
docker compose -p happy-vault -f /tmp/compose.vault.srv.yml up -d --no-deps --force-recreate vaultwarden
```

For the filler, `make filler-down` and enable the old unit again.
