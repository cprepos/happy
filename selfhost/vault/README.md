# Vaultwarden

A self-hosted Bitwarden-compatible server on prep-ml for all of your devices:
the phone, prep-air, prep-pro and the browser extensions. The browser agent's
secret filler (`browser-stack/browser/filler`) also reads it, through its own
restricted account. Design: [docs/plan.md](docs/plan.md).

- One standalone container, `vaultwarden` (`docker run`, outside every
  compose project, labelled `happy.standalone=vaultwarden`), with
  `--restart unless-stopped`. `scripts/vaultwarden.sh` creates and runs it
  (`make vault-up`, `vault-down`, `vault-logs`, `vault-status`); the image is
  pinned by digest there. Docker is enabled at boot, so the vault comes back
  after a reboot. No `browser-*` target touches it. `make stack-up` /
  `stack-down` (in `selfhost/`) run the vault and then the browser stack.
- The secret filler is not a container: it runs on the host as the account
  `happy-filler` (the user unit `happy-filler.service`, 127.0.0.1:6091, data in
  `/srv/happy-filler`); see `browser-stack/browser/filler/README.md`.
- It listens on `127.0.0.1:8222` only. From outside, the only way in is the
  existing Caddy :443 site **`https://vault.girthbass.duckdns.org`**. Caddy
  answers `/admin` there with 404. No new port is open.
- Data lives in two named Docker volumes, never under `/home/prep`, owned by
  uid 1991 (Vaultwarden): `vaultwarden-data` (`/data`: the database,
  attachments, keys) and `vaultwarden-config` (`/etc/vaultwarden`, read-only
  in the container: `vaultwarden.env` and `env-backups/`). No make target
  needs sudo, and nothing removes a container or volume.

## Server setup (once, in order)

This host's settings (domain, agent email, LAN addresses, uids)
are in `vault/.env`, which is not committed; start from `.env.example`.
Caddy is a host service: `vault-caddy-apply` fills `caddy-vault.conf` with
`VAULT_DOMAIN` and adds it to `CADDYFILE`.

```
cp vault/.env.example vault/.env                       # then edit it
make vault-up VAULT_OWNER_EMAIL=<your vault email>     # creates the volumes, the env file and the container
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
5. `make vault-backup-cron` (once), then `make vault-backup` and `make
   vault-backup-check` (see Backups).

The agent account for the secret filler (no organization: its logins sit in
its own vault) and the filler's own setup (`make filler-account-setup`, then
`filler-setup` as happy-filler) are in `browser-stack/browser/filler/README.md`.

### The env file

`vaultwarden.env` in the volume `vaultwarden-config` (uid 1991, 0600) holds
`ORG_CREATION_USERS` and, while the admin panel is on, `ADMIN_TOKEN`: only
the argon2 hash of the password, which `make vault-admin-on` asks for on the
terminal. Each edit first copies the file into `env-backups/<ts>` in the same
volume. Docker does not read the file: the volume is mounted read-only at
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
make vault-status         # health, 127.0.0.1-only bind, public /alive, public /admin = 404, env keys set/unset
make vault-up | vault-down | vault-logs   # vault-up on a running container does nothing
make vault-admin-on | vault-admin-off     # edits vaultwarden.env, then restarts the container
make vault-backup | vault-backup-check | vault-backup-status | vault-restore TARBALL=...   # see Backups
```

`make status` (the main health check) runs `vault-status` too.

## Backups

`scripts/vault-backup.sh`, through make, from prep's cron. No sudo: each step
runs in prep's Docker as the data's own uid, with no network, a read-only root
and no capabilities. Nothing is ever deleted and nothing lands under
`/home/prep`.

**What is covered.**

- `vault-<ts>.tar.gz`: an online SQLite snapshot of the running container
  (`vaultwarden backup`) as `db.sqlite3`, with `attachments/`, `sends/`,
  `config.json` and `rsa_key*` from `vaultwarden-data`, and `vaultwarden.env`
  and `env-backups/` from `vaultwarden-config`. Written as uid 1991.
- `filler/filler-<ts>.tar.gz`: the filler's `secrets/`, `state/`,
  `policy.json`, `policy-backups/`, `audit/` and `trash/` from
  `/srv/happy-filler` (not `releases/`, `current`, `pipe-bin/`, `inbox/` or
  `outbox/`), read through a read-only bind as uid 1990 and written as 1990,
  so Vaultwarden's uid never reads the filler's credentials.

Each tarball has a `.sha256` next to it, checked after every copy.

**Where it goes.**

| location | | |
|---|---|---|
| `/girth/backup/vault` | primary, ZFS `girth/backup/vault` | a snapshot `girth/backup/vault@vault-<ts>` after every backup |
| `/mnt/ai-data/backups/happy-vault` | mirror, ext4 | missing tarballs copied from the primary |

Both are 1991:1991 0711, with `filler/` as 1990:1990 0700. In each the newest
30 (`VAULT_BACKUP_KEEP`) of each kind stay; older ones move to `retired/`. A
missing or unwritable location, a hash mismatch or a refused snapshot fails
loudly and the run exits non-zero.

**Targets** (from `selfhost/`):

```
make vault-backup          # tarballs, snapshot, mirror
make vault-backup-check    # restore the newest tarball of each location into a throwaway
                           # container: integrity, users, organizations, ciphers, rsa_key, same
                           # sha256 everywhere; the filler tarball's sha256 and secrets/
make vault-backup-status   # newest tarball per location and its age (STALE past 26 h), newest snapshot
make vault-restore TARBALL=vault-<ts>.tar.gz           # from the primary (or its retired/)
make vault-restore TARBALL=/path/to/vault-<ts>.tar.gz  # a mirror's or a snapshot's copy
make vault-backup-cron     # add the two cron lines below, each only if missing
```

**Restore.** `vault-restore` checks the tarball's sha256 first (a bad one
changes nothing), stops the container `vaultwarden`, moves the current contents
of `vaultwarden-data` into `/girth/backup/vault/before-restore-<ts>/` (kept),
unpacks the tarball into the volume (`vaultwarden.env` and `env-backups/` are
left out; `vaultwarden-config` is not touched), starts the container and waits
for `/alive`. Logins made after the tarball's time are lost from the live vault
(they stay in `before-restore-<ts>/`). The filler is restored by hand: as
happy-filler, `make filler-lock`, unpack the files you need from its tarball
into `/srv/happy-filler`, then `make filler-up`.

**Cron** (prep's crontab; output in `~/.local/state/happy/vault-backup.log`):

```
15 4 * * *  make -C /home/prep/happy/selfhost vault-backup >> ~/.local/state/happy/vault-backup.log 2>&1
45 4 * * 0  make -C /home/prep/happy/selfhost vault-backup-check >> ~/.local/state/happy/vault-backup.log 2>&1
```

The old nightly user timer `happy-vault-backup.timer`, which backed up the
compose volumes, is retired; its units are in the repo's
`trash/*_vault-backup-timer/`.

Until November 11, 2026 Vaultwarden and the filler ran as the compose project
`happy-vault`; its compose file and the `vault-init` / `vault-migrate` scripts
are in the repo's `trash/*_vault-compose/`.
