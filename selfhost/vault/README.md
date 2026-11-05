# Vaultwarden

A self-hosted Bitwarden-compatible server on prep-ml for all of your devices:
the phone, prep-air, prep-pro and the browser extensions. The browser agent's
secret filler (`selfhost/browser/filler`) also reads it, through its own
restricted account. Design: [docs/plan.md](docs/plan.md).

- Its own compose project, `happy-vault` (`compose.vault.yml`), with
  `restart: unless-stopped`. Docker is enabled at boot, so the vault comes back
  after a reboot. No `browser-*` target touches it.
- It listens on `127.0.0.1:8222` only. From outside, the only way in is the
  existing Caddy :443 site **`https://vault.girthbass.duckdns.org`**. Caddy
  answers `/admin` there with 404. No new port is open.
- Data lives in `/srv/happy-vault` (outside `/home/prep`), owned by uid 1991.

## Server setup (once, in order)

```
make vault-init VAULT_OWNER_EMAIL=<your vault email>   # sudo: /srv/happy-vault + env file
make vault-up
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
its own vault) is in `selfhost/browser/filler/README.md`.

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
make vault-backup         # one tarball now
make vault-restore-check  # restore the newest tarball in a throwaway container; counts users, orgs, ciphers
make vault-backup-timer   # install + enable the nightly systemd user timer
make vault-admin-on | vault-admin-off   # sudo
```

`make status` (the main health check) runs `vault-status` too.

## Backup and restore

`make vault-backup` takes an online SQLite snapshot (`vaultwarden backup`) and
writes `/srv/happy-vault/backups/vault-<UTC timestamp>.tar.gz`. The tarball
holds `db.sqlite3`, `attachments/`, `rsa_key*` and `config.json`. The nightly
timer (`happy-vault-backup.timer`, 04:15, catches up after downtime) runs the
same target. The newest 30 stay in `backups/`. Older ones move to
`backups/retired/` and are never deleted.

`rsa_key.pem` signs login tokens, so backups never go under `/home/prep`.
Copying them off the machine is up to you. A tarball holds only data that is
already encrypted with your master password, except `rsa_key.pem`.

Check that a backup restores (safe at any time):

```
make vault-restore-check
```

To restore for real (as root):

```
make vault-down
sudo mv /srv/happy-vault/data /srv/happy-vault/data.before-restore.$(date +%s)
sudo install -d -o 1991 -g 1991 -m 0700 /srv/happy-vault/data
sudo tar xzf /srv/happy-vault/backups/vault-<ts>.tar.gz -C /srv/happy-vault/data
sudo chown -R 1991:1991 /srv/happy-vault/data
make vault-up
```
