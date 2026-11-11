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
5. Make sure the host's backups cover the vault (see Backups).

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
```

`make status` (the main health check) runs `vault-status` too.

## Backups

Nothing in this repo makes backups any more: the host's own cron does. What
has to be in them:

- the Docker volumes `vaultwarden-data` (the database, attachments, keys) and
  `vaultwarden-config` (`vaultwarden.env` and `env-backups/`);
- `/srv/happy-filler`: the filler's `policy.json`, `policy-backups/`,
  `secrets/`, `state/`, `audit/` and its releases.

The filler's `secrets/` are the agent account's vault credentials: keep their
copies where only root (or uid 1990) can read them, not next to the vault's.

The nightly user timer `happy-vault-backup.timer` and `make vault-backup` /
`vault-restore*` are retired (they backed up the old compose volumes and had
been failing on missing mirror directories); the unit files and
`scripts/vault-backup.sh` are in the repo's `trash/*_vault-backup-timer/`.

Until November 11, 2026 Vaultwarden and the filler ran as the compose project
`happy-vault`; its compose file and the `vault-init` / `vault-migrate` scripts
are in the repo's `trash/*_vault-compose/`.
