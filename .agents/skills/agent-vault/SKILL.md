---
name: agent-vault
description: >
  The agents' password manager: the self-hosted Vaultwarden (Bitwarden-compatible) at
  vault.girthbass.duckdns.org, its "agent" account, and the secret filler that types those logins
  into the agent browser without the model ever seeing a value, plus the vault_* tools (vault-mcp)
  that create, rotate, trash, restore, compare and pipe logins. Use when an agent needs to sign
  in to a site, create or rotate a login, log a CLI in with a stored token, when the user asks
  which logins the agents have, why a login didn't fill, to add or fix a login, or about the
  vault, the filler, Bitwarden or passwords for the agents. Works the same on prep-ml, prep-air
  and prep-pro: the tools always run on prep-ml.
---

# Agent vault (Vaultwarden + secret filler)

<!-- Installed to ~/.claude/skills/agent-vault/ on prep-ml, prep-air and prep-pro by
     `make mcp-register` (selfhost/scripts/mcp-register.py). Edit the repo copy,
     .agents/skills/agent-vault/SKILL.md, not an installed one. -->

## Where things run

Everything below lives on **prep-ml** (the Linux box): Vaultwarden, the filler, the browser
bridge and its Chromium, and both MCP servers. It is the same on every machine:

- **On prep-ml** the `vault` and `happy-browser-bridge` MCP entries run
  `node selfhost/vault-mcp/mcp.mjs` and `node selfhost/browser/bridge/mcp.mjs` directly.
- **On prep-air and prep-pro** (Macs) the same entries are a `/bin/sh -c` wrapper that runs
  `ssh -o BatchMode=yes prep-ml /usr/bin/node <script>` and hands prep-ml the chat's
  `HAPPY_SESSION_ID` (plus `CLAUDE_CODE_SESSION_ID` and `HAPPY_FORKED_FROM_SESSION_ID`). The
  tools behave exactly as on prep-ml: same logins, same policy, same browser (it is on prep-ml,
  and its live link works from the phone).

So on a Mac: the paths, the containers and the `make` targets named here are **prep-ml's**, not
the Mac's. Don't look for them locally, and don't try to install anything on the Mac for the
vault. `vault_pipe` runs its command **on prep-ml** too, so it logs in prep-ml's CLI (for
example prep-ml's `gh` or docker), not the Mac's.

If the `vault_*` or `browser_*` tools are missing in a session, that session's agent was started
before the entries were registered: tell the user to restart the session (a new session reads
them at start). If the tools work but every chat-specific login is refused and the session acts
like chat `none`, the session was started outside Happy (no `HAPPY_SESSION_ID`).

## What it is

- **Vaultwarden** on prep-ml, container `happy-vault-vaultwarden-1`, behind Caddy at
  https://vault.girthbass.duckdns.org (on prep-ml: http://127.0.0.1:8222). Data and env file on
  prep-ml under `/srv/happy-vault/`. Nightly backup timer `happy-vault-backup.timer`.
- **Agent account:** `agent@vault.girthbass.duckdns.org`. This is the password manager for all
  agents. Its own (personal) vault holds the logins; there is **no organization**. Only the user
  knows its master password. The user's own vault account is separate and is never used by
  agents.
- **Secret filler:** on prep-ml, runs as its own Linux account `happy-filler`, as that account's
  systemd user unit `happy-filler.service`, 127.0.0.1:6091 only, installed under
  `/srv/happy-filler/` (owned by happy-filler; `current` -> `releases/<sha>`). prep cannot change
  it. It is enrolled with the agent account's API key and holds the unlocked key in memory. It
  types logins (bridge token) and, through the vault tools' own token, creates, changes, trashes
  and restores them. It never purges anything.

## How an agent uses it (browser tools of the happy-browser-bridge MCP)

1. `browser_list_secrets()`: names like `girthbass-gmail.password`, each one's allowed hosts
   and kind. Never values. The name is the vault item name slugified ("Girthbass gmail" ->
   `girthbass-gmail`).
2. On a sign-in page: `browser_login(session_id, "<login>")` (finds the fields, types, submits,
   handles a stored TOTP), or `browser_fill_secret` for split or unusual forms.
3. One clear match: use it and tell the user which login, by name. Several or unclear: ask the
   user which login. None, a refusal, a CAPTCHA or a phone/SMS second factor: tell the user and
   `browser_wait_for_human`.
4. Never ask the user to type a password in chat, and never have the user type the master
   password into the agent browser.

After a fill the session is **tainted**: `browser_eval_js`, full `browser_get_html`,
value selectors, copy keys, fork and save-auth-profile are refused, and every result is scrubbed.
Use `browser_observe`, `browser_find_elements`, `browser_get_html(text_only=true)`.

## Vault tools (vault MCP, `selfhost/vault-mcp/mcp.mjs`)

These are the only way an agent touches the vault. Never use the bw CLI, the Vaultwarden API,
the filler's files, `docker exec`, or the token file directly, on any machine.

- `vault_list` / `vault_search`: metadata only (id, name, fill name, username, URIs, which
  fields are set, trashed).
- `vault_create {name, uris, username, password?: {length, classes, exclude}}`: the filler
  generates the password, and nobody sees it. To set it on a site, use `browser_fill_secret`
  with `<fill name>.password` on the sign-up form.
- `vault_update {id, name?, uris?, username?, rotate_password?: spec}`: rotate in the vault
  first, then fill the site's change-password form with `browser_fill_secret`. The old password
  stays in the item's history.
- `vault_remove {id}` moves the login to the trash (soft delete). `vault_restore {id}` brings it
  back. There is no purge.
- `vault_compare {id, field, algo: sha256|sha512|bcrypt|argon2, digest, salt?}` returns
  `{match}`. It is rate limited (20 per login per 10 minutes).
- `vault_pipe {id, field, target, args?}` feeds the value to the stdin of a command from the
  root-owned policy's `pipe_targets` (for example docker-login or gh-token), **on prep-ml**, and
  returns its exit code and scrubbed output.
- Permissions come from the policy, `clients.<c>.manage`. A refusal names the missing
  `manage.*` key; the user changes it with `make filler-policy-edit` (on prep-ml, as
  happy-filler).
- The vault tools' client token lives in prep's secrets folder on prep-ml and is read by the
  server itself. Never read or print it. The servers are registered with every harness on all
  three machines by `make mcp-register` (run on prep-ml).

## Which chats can use which logins

The policy is on prep-ml at `/srv/happy-filler/policy.json`. Its shape (no values in it):
```
{"version":1,"default_client":"agent","clients":{"agent":{"all_items":true,"secrets":{},"manage":{"create":true,"update":true,"remove":true,"compare":true,"pipe":[]}}},"chats":{},"pipe_targets":{}}
```
- `all_items`: every personal login in the agent vault, filled **only on the https hosts in
  that item's own saved URIs** (plus the vault's equivalent domains). A login without an https
  URI is not listed.
- A new or edited login shows up within about 15 s, with no restart.
- Chats with no id (Happy Agent, or a session started outside Happy) send chat `none`, which only
  `default_client` serves.

## Common fixes

- **"Login not allowed on this host":** the item's saved URI doesn't match the sign-in page
  (e.g. Gmail signs in on `accounts.google.com`, not `www.gmail.com`). Either the user adds
  that https URI to the item in the web vault (logged in as the agent account), or the agent adds
  it with `vault_update` (`uris`) if the policy gives `manage.update`, or the policy gets an
  explicit entry.
- **Login missing from the list:** the item has no https URI, sits in an organization, or
  shares its name with another item (both are refused until one is renamed).
- **Tools missing on a Mac:** see "Where things run" (restart the session). If they still are
  missing, `make mcp-register` on prep-ml puts them back; `make mcp-check` shows each config.

## Make targets (prep-ml only, from /home/prep/happy/selfhost)

On a Mac none of these exist locally. Run the safe ones only when they help the user, as
`ssh -o BatchMode=yes prep-ml make -C /home/prep/happy/selfhost <target>`.

- **As prep, no sudo, safe to run:** `make filler-status`, `make filler-audit`,
  `make filler-test`, `make filler-smoke`, `make vault-status`, `make vault-mcp-test`,
  `make mcp-check`, and prep's halves of a token handoff: `make filler-token-take` (outbox tokens
  into prep's secrets, 0600), `make filler-controller-token-give` (the browser controller token
  into the filler's inbox).
- **Admin targets run only as `happy-filler` on prep-ml. Agents cannot run them** (no account,
  no password, and they refuse any other account); give the user the commands to type on
  prep-ml: `su - happy-filler`, then `make -C /home/prep/happy/selfhost <target>` (or
  `filler-admin <command>`). They are: `filler-install COMMIT=<sha>` then `filler-restart`
  (deploy a reviewed commit), `filler-up`, `filler-down`, `filler-restart`, `filler-lock`,
  `filler-logs`, `filler-items` (names, item ids, hosts; no values), `filler-enroll`,
  `filler-policy-edit`, `filler-seed-policy`, `filler-init`, `filler-setup COMMIT=<sha>` (first
  install), `filler-token-issue NAME=bridge-client|vault-client [FILLER_ROTATE=1]`,
  `filler-controller-token-take`, `filler-outbox-clear`.
- **No sudo for anything filler-related**, except the one-time `make filler-account-setup
  COMMIT=<sha>`, already done. Never suggest it again unless the happy-filler account is missing.
- Filler code lives in `selfhost/browser/filler`, bridge side in
  `selfhost/browser/bridge/lib/secrets.mjs`. Changes go through a commit pushed to `fork`, then a
  `filler-install` of that SHA.
- The bridge's and the vault's MCP processes are per chat (on a Mac, one ssh per server per
  session). Happy Agent's single process on prep-ml is a child of the `happy-agent` container's
  `happy-agent-linux-x64 run`; killing it respawns it with fresh code (do this only when no
  link is in user/takeover, unless the user says restart anyway).

## Rules

- Never print secrets: the filler's key files, the client tokens, the API key, the master
  password, `docker exec ... env` values, policy item values. `filler-items`,
  `browser_list_secrets` and `vault_list` are safe.
- Never `docker exec`, `su`, `sudo` or a container to act as happy-filler or read
  `/srv/happy-filler/secrets`; admin targets are the user's to type.
- Never ask the user for happy-filler's password, and never put it in a command.
- Sign-up on the vault is closed (no signups, no admin token, no organization), so new accounts
  need an invitation.
- Known limit: on prep-ml, accounts in the docker or sudo groups (including `prep`) can
  technically reach the filler's files and memory through a container, so the protection is
  against the model through the tools and against prep's ordinary processes, not against a
  deliberate docker attack.
