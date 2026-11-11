# Secret filler

The browser agent logs in to client sites without ever seeing a password,
username or one-time code. It asks for a secret by name (`github.password`),
and this service checks the request, reads the value from Vaultwarden and types
it into the agent's browser session itself. The value is never returned, and
any copy of it that turns up in a later tool result is replaced with
`[secret:github.password]`.

- Runs in Docker as uid 1990 (the service `filler` of `selfhost/vault/compose.vault.yml`), with its data
  in `/srv/happy-filler`, and listens only on `127.0.0.1:6091`.
- Logs in to the vault with the agent account's API key and user key. It never
  holds the master password (enrollment uses it once to read the API key and
  derive the user key).
- Reads the **personal vault of the agent account**
  (`VAULT_AGENT_EMAIL` in `selfhost/vault/.env`). There is no organization: that
  account holds only the logins agents may use, and your own account stays
  separate. A chat reaches an item only through a name its client lists in the
  filler's own policy (prep cannot write it), and an item may be listed by one client only.
- Types a value only into a field of the right kind, only on a page that is
  https on a host that appears both in the vault item's URIs and in the policy,
  and only into a session bound to the same chat and client.
- Also serves the agents' vault tools (`browser-stack/vault-mcp`, see "Vault
  tools" below): list, create, change, trash and restore logins with
  passwords it generates itself, compare a value against a hash, and pipe a
  value into an allowlisted command's stdin. No route returns a value to the
  model.
- Audit log: `/srv/happy-filler/audit/YYYY-MM.jsonl` records names, hosts and
  outcomes. It never records values. Read it with `make filler-audit`.

The design and its limits are in `selfhost/vault/docs/plan.md`.

## How it runs

The filler is a container: the service `filler` of the vault's compose
project (`happy-vault`, `selfhost/vault/compose.vault.yml`), built from
`Dockerfile` here (node 22, pinned by digest; the app files root-owned and
read-only). It runs as uid 1990, the owner of `/srv/happy-filler`, with
`--disallow-code-generation-from-strings`, a read-only root filesystem, every
capability dropped and `no-new-privileges`. It uses the host network so it can
bind `127.0.0.1:6091` itself and reach Vaultwarden on `127.0.0.1:8222` and the
browser controllers on `127.0.0.1:8010` and 8100-8131. `/srv/happy-filler`
is mounted read-only at `/filler`, with only `state/` and `audit/` writable.
`restart: unless-stopped`: it comes back after a crash or reboot and unlocks
itself from its key files; `make filler-lock` stops it until `make filler-up`.

Its admin commands (`scripts/admin.mjs`) run once each in the same image, as
the compose service `filler-admin` (profile `admin`, `/srv/happy-filler`
writable), through make. Agents give you these commands to type; they do not
run them.

The vault tools' MCP server (`browser-stack/vault-mcp`) and the bridge's stdio
MCP server stay on the host: each agent harness spawns them, and `vault_pipe`
runs host commands (gh, docker, gpg) with your own configs.

Token handoff, no root involved (`make vault-tokens` does all four):

| target | does |
|---|---|
| `make filler-token-issue NAME=bridge-client` (or `vault-client`) | in the container: a new token, its SHA-256 to `secrets/`, the plaintext once to `/srv/happy-filler/outbox/<NAME>-token` (0640, group prep). Refuses if one exists, unless `FILLER_ROTATE=1` |
| `make filler-token-take` | as prep: each outbox token into prep's secrets dir (0600): `bridge-client-token` to `~/.local/share/happy-browser/secrets/filler-client-token`, `vault-client-token` to `~/.local/share/happy-vault-mcp/secrets/vault-client-token`; the outbox file moves to prep's trash |
| `make filler-controller-token-give` | as prep: copies `~/.local/share/happy-browser/secrets/api-token` into `/srv/happy-filler/inbox/` |
| `make filler-controller-token-take` | in the container: that file into `secrets/controller-token` (0400); the inbox file moves to trash |

`outbox/` is 1990:prep 2770 (prep may move files out); `inbox/` is 1990:prep
3730 (prep may drop a file in, but not list it). A token is read without
following a symlink and only from a regular, singly linked file of the other
uid's that holds nothing but a token (`scripts/handoff-copy.mjs`).

Before November 2026 the filler ran as a systemd user unit of its own account,
`happy-filler`. That unit is stopped and disabled; it, `filler-admin.sh` and
`filler-account-setup.sh` are in the repo's `trash/*_filler-systemd/`. The
data in `/srv/happy-filler` is the same.

## Setup (once)

From `selfhost/`, after `cp vault/.env.example vault/.env` and filling it in
(domain, agent email, `/srv` paths, uids):

1. **Register the agent account.** The agent account's email
   (`VAULT_AGENT_EMAIL`) is invited on the server (sign-ups are closed, so only
   an invited email can register). At `https://$VAULT_DOMAIN` choose **Create
   account** with that email and a long random master password; keep the
   password in your own vault. Its KDF must be **PBKDF2-SHA256** (Settings >
   Security > Keys > Encryption key settings); the filler refuses Argon2id.
2. **Add the agent's logins.** Log in as the agent account (Bitwarden app or
   web vault) and add each login agents may use, with its https URL and,
   if wanted, its TOTP seed (Authenticator key). Nothing else goes in this
   vault. You can add more at any time.
3. `make vault-init` (sudo, once): `/srv/happy-vault`, the `/srv/happy-filler`
   tree (uid 1990; `audit/`, `outbox/`, `inbox/` shared with your group), then
   in the container an empty policy.
4. `make browser-init` if the browser stack is new (the controller token).
5. `make vault-tokens`: both client tokens and the controller token.
6. `make filler-seed-policy`:
   `{"version":1,"default_client":"agent","clients":{"agent":{"all_items":true,"secrets":{},"manage":{"create":true,"update":true,"remove":true,"compare":true,"pipe":[]}}},"chats":{},"pipe_targets":{}}`
   (a policy with content is left alone).
7. `make vault-enroll BACKEND=shared` (a terminal): asks only for the agent's
   email (Enter accepts the default) and master password, and reads the
   account's API key from the vault itself, as the web vault's "View API key"
   does. If that fails (for example, the account has two-step login), it asks
   for the API key's `client_id` and `client_secret` instead (Settings >
   Security > Keys > View API key). Only the API key and the derived user key
   are stored, as 0400 files. Then it restarts the filler.
8. `make stack-up` (or `make vault-up`), `make filler-items` (each login's
   name, item id and https hosts, never a username or password), restart the
   bridge, and `make vault-status`.

## Policy: `/srv/happy-filler/policy.json` (uid 1990, 0640)

The filler refuses a policy file that is group- or world-writable, a
symlink, or owned by anyone but its own uid (or root). Edit it with
`make filler-policy-edit` (vi, in the container).

```json
{
  "version": 1,
  "clients": {
    "acme": {
      "secrets": {
        "github": { "item_id": "<item uuid>", "hosts": ["github.com"], "fields": ["username", "password", "totp"] }
      }
    }
  },
  "chats": { "<happy session id>": "acme" }
}
```

- `item_id` is the login's uuid in the agent account's vault (`make
  filler-items` lists them). Open the item in
  the web vault (logged in as the agent): the URL ends in `itemId=<item_id>`.
- `org_id` and `collection_id` belonged to an earlier, organization-based
  design. A policy that still has them is refused.
- `custom_fields` (optional, e.g. `["token"]`) names the item's Bitwarden
  custom fields this client's vault tools may see and use (`vault_compare`,
  `vault_pipe` with `custom_field`). Names are exact and case-sensitive, 1..64
  of `A-Z a-z 0-9 space _ . -`. Custom fields are never fillable in a browser.
  A secret needs `fields`, `custom_fields`, or both. An `all_items` client
  reaches every custom field of its logins.
- `hosts` must also appear as https URIs on the vault item. Matching is exact:
  `github.com` does not allow `www.github.com`.
- A chat with no entry in `chats` can use no secrets, unless the policy sets
  `default_client` (below).
- `"default_client": "<slug>"` (optional) must name a client in `clients`, or
  the policy is refused. Every chat without its own entry in `chats` then uses
  that client, and so does a bridge process with no chat id at all (a Happy
  Agent daemon serving many chats has no `HAPPY_SESSION_ID`; it sends the chat
  `none`, which only `default_client` serves and which may not be a key in
  `chats`). A chat listed in `chats` always uses its own client. The audit
  records `"path":"mapped"` or `"path":"default"` for each fill.
- An item may belong to only one client. All clients' logins share one
  vault, so this file is what keeps them apart: check each `item_id`.
- The filler reloads the policy whenever the file changes. While the file is
  invalid, every fill is refused.

- `"all_items": true` on a client (at most one per backend) lets it use every login in
  the agent account's own vault, with no policy edit per login:
  - the name is the item's name as a slug: "GitHub (work)" is `github-work`,
    so `github-work.password`; `browser_list_secrets` shows each login with
    the fields it has (username, password, totp);
  - each login is typed only on the https hosts of its own saved URIs, matched
    exactly as `hosts` is (`github.com` does not allow `gist.github.com`);
    a login with no https URI cannot be used and is not listed;
  - the vault is re-read on the usual sync cadence (at most 15 s old), so a
    login added later shows up without a restart;
  - names in the client's `secrets` take precedence, and an item any client
    lists by `item_id` never appears under `all_items`, so its own `hosts` and
    `fields` keep applying. Two logins with the same name are both refused
    until one is renamed. Organization items are never included.

### Equivalent domains (`all_items` only)

An `all_items` login also fills on the vault's equivalent domains, the way the
Bitwarden extension does. A login saved for `https://www.gmail.com` fills on
`accounts.google.com`, because Bitwarden's global equivalent domains put
gmail.com, google.com and youtube.com in one group.

- The groups come from the vault's sync: the agent account's own groups (web
  vault, Settings > Domain rules) and the global groups it has not excluded.
  Excluding a global group there takes effect on the next sync (at most 15 s).
- A page host is allowed if it is a saved host, as before, or if its
  registrable domain (`accounts.google.com` -> `google.com`; `www.foo.co.uk`
  -> `foo.co.uk`) is in a group with the saved host's registrable domain. The
  registrable domain comes from a small vendored public suffix list
  (`lib/psl.mjs`, no network at runtime). A group entry that is itself a
  public suffix (`net.cn`, `myshopify.com`) is ignored, so `foo.co.uk` never
  grants `bar.co.uk` and no group grants every shop on a hosting platform.
- Only https pages, and only URIs with the default match detection ("Base
  domain"). A URI set to Host, Starts with, Exact, Regular expression or Never
  in the vault keeps its exact host.
- A saved host whose domain is in no group gets no subdomain matching:
  `github.com` still does not allow `gist.github.com`. Inside a group, a
  sibling subdomain such as `mail.gmail.com` from `www.gmail.com` is allowed,
  as in the extension.
- `"equivalent_domains": false` on the client turns this off. Its logins then
  fill only on their exact saved hosts.
- Explicit `secrets` entries with their own `hosts` never use equivalence.
  That list is the operator's precise choice, and data from the vault must not
  widen it.
- `browser_list_secrets` adds a short `equivalents` label, for example
  `"+ google.com, youtube.com equivalents"`. `make filler-items` shows
  `www.gmail.com (+ google.com, youtube.com equivalents)`. A host refusal
  names the equivalents too. A fill allowed this way is audited with
  `"via":"equivalent_domains"` and `"equivalent_of":"<saved host>"`.

### Backends: more than one vault

`"backends"` names the vaults the filler reaches, and each client names the
one it uses in `"backend"`:

```json
{"version":1,
 "backends":{"shared":{"type":"vaultwarden"},
             "instimate":{"type":"vaultwarden","url":"http://127.0.0.1:8223"}},
 "clients":{"agent":{"backend":"shared","all_items":true},
            "instimate":{"backend":"instimate","all_items":true}},
 "chats":{"<happy session id>":"instimate"},
 "default_client":"agent","pipe_targets":{}}
```

- A client uses exactly one backend. Every list, fill, login and vault-tool
  call of a chat goes to its client's backend and no other: an item id means
  something only within its backend, so an id from another backend (guessed,
  or even written into this client's `secrets`) is simply not found there.
- `all_items` (one client per backend) and "an item belongs to one client"
  hold per backend, so an Instimate `all_items` client sits next to the
  shared one.
- A backend's name is 1..32 of `a-z 0-9 _ -`. `type` is a provider type;
  every other key is that provider's own (non-secret) setting. For
  `vaultwarden`: `url` (default `VAULT_URL`). Secrets stay files: `shared`
  keeps today's `secrets/vault-*`; another backend reads its own from
  `secrets/<name>/`.
- Each backend's provider is built on first use. One that is not enrolled or
  fails to start answers 503 to its own chats only; `/healthz` shows each
  backend under `backends` (`unlocked` at the top level is the default
  client's backend, normally `shared`).
- A policy without `backends` keeps working: it reads as `{"shared":
  {"type": "vaultwarden"}}` with every client on it, and its clients may
  not name another backend. With `backends`, every client must name one.
- Values typed from any backend are scrubbed and taint their browser session
  the same way; a session holding one chat's secret refuses another chat.

### Every chat shares the agent's logins

What `make filler-setup` seeds, and the recommended setting:

```json
{"version":1,"default_client":"agent","clients":{"agent":{"all_items":true,"secrets":{},"manage":{"create":true,"update":true,"remove":true,"compare":true,"pipe":[]}}},"chats":{},"pipe_targets":{}}
```

Or, listing each login by hand instead of `all_items`:

```json
{"version":1,"default_client":"agent","clients":{"agent":{"secrets":{"<name>":{"item_id":"<uuid>","hosts":["example.com"],"fields":["username","password","totp"]}}}},"chats":{}}
```

The trade-off: any chat, including Happy Agent chats and any other process
holding the bridge's client token, can ask for a fill of any of these logins
(with `all_items`, of anything you put in the agent account's vault), so there
is no separation between chats any more. What still holds: values
never reach the model (the filler types them and every result is scrubbed),
a value is typed only on an https page on a host that both the vault item and
the policy list (for `all_items`, or one of its equivalent domains), only into a field of the right kind, and a browser session
that holds one chat's secret refuses fills for another chat. To give one
client's chats their own logins later, add that client and its chats; mapped
chats never fall back to the default.

## Vault tools (`browser-stack/vault-mcp`)

Every agent vault interaction goes through one stdio MCP server,
`browser-stack/vault-mcp/mcp.mjs`, with one strict tool per action. Its server
instructions tell agents not to use the bw CLI, the Vaultwarden API, the
filler's files or docker. Each tool is a thin client of the filler's
`POST /v1/vault/<action>`:

| tool | what it does | needs (`manage.*`) |
|---|---|---|
| `vault_list` / `vault_search` | the logins the chat reaches: id, name, fill name, username, URIs, which fields are set, `custom_fields` (names only), trashed. Never a password, TOTP or custom field value | (any client) |
| `vault_create` | a new login; the filler generates the password (default 32 characters from all classes, 16..128) | `create` (only with `all_items`) |
| `vault_update` | rename, new URIs or username, `rotate_password` (a new random one; the old one goes to the item's password history) | `update` |
| `vault_remove` | **soft delete** to the vault trash | `remove` |
| `vault_restore` | back from the trash | `remove` |
| `vault_compare` | `{match: true\|false}` against a sha256/sha512 (hex, optional salt prefix), bcrypt or argon2 (PHC) digest; 20 per client and login per 10 minutes | `compare` |
| `vault_pipe` | the value on the stdin of an allowlisted command; returns its exit code and scrubbed output | `pipe: [target names]` |

`vault_compare` and `vault_pipe` take exactly one of `field` (`username`,
`password`, `totp`; totp is the stored seed, not a current code) and
`custom_field` (a custom field's exact name from `vault_list`, e.g. `token`).
Text, hidden and boolean custom fields have values (a boolean is `true` or
`false`); linked ones do not. An unknown name is a 404 that lists the
login's custom field names; two fields with the same name are a 409
(ambiguous). The audit records `field_kind: "custom:<name>"`, never a value,
and the pipe's output is scrubbed to `[secret:<name>]`.

- New passwords are always random and generated inside the filler. An agent
  never supplies or sees one: it sets a new password on a site with
  `browser_fill_secret` (field `password`) on the change-password form, after
  `vault_update` with `rotate_password`.
- There is no purge or hard delete anywhere. Vaultwarden empties its trash
  only if `TRASH_AUTO_DELETE_DAYS` is set in `/srv/happy-vault/vaultwarden.env`.
- Writes go only to the agent account's personal logins that the chat's
  client reaches (its listed item ids, or for an `all_items` client the
  personal logins no client lists). `create` requires `all_items`: a login
  created by another client would land under the `all_items` client.
- A new name must not collide with a fill name already in use (409).

**Two tokens.** The bridge's client token (`secrets/client-token.sha256`)
reaches only the fill routes, and the vault tools' token
(`secrets/vault-client-token.sha256`) only `/v1/vault/*`. `make
vault-tokens` (or `make filler-token-issue NAME=vault-client` and `make
filler-token-take`) puts the vault tools' token in
`~/.local/share/happy-vault-mcp/secrets/vault-client-token` (yours, 0600;
`HAPPY_VAULT_MCP_HOME` moves it). If the two hashes are the same, the filler
turns the vault routes off. `FILLER_ROTATE=1` on `filler-token-issue` rotates
one (see Rotation).

**Registering the server** with the agent harnesses is done by `make
mcp-register` in `selfhost/Makefile`; the command is
`node browser-stack/vault-mcp/mcp.mjs`, with `HAPPY_SESSION_ID` set by Happy for
the chat id (a process without one sends `none`, served by `default_client`).

### `manage` and `pipe_targets` in the policy

```json
{
  "version": 1,
  "default_client": "agent",
  "clients": {
    "agent": {
      "all_items": true, "secrets": {},
      "manage": { "create": true, "update": true, "remove": true, "compare": true, "pipe": ["docker-login", "gh-token"] }
    }
  },
  "chats": {},
  "pipe_targets": {
    "docker-login": { "argv": ["docker", "login", "--username", "{username}", "--password-stdin", "{arg:registry}"], "args": { "registry": "[a-z0-9.-]+(:[0-9]+)?" } },
    "gh-token": { "argv": ["gh", "auth", "login", "--hostname", "github.com", "--with-token"] }
  }
}
```

- `manage` keys are `create`, `update`, `remove`, `compare` (true or false)
  and `pipe` (names from `pipe_targets`). A missing `manage` means list and
  search only.
- A `pipe_targets` entry is a command run without a shell. Each argv element
  is a literal, or exactly `{username}` (the login's username) or
  `{arg:<slot>}`; `argv[0]` is literal. Every slot needs a pattern in `args`,
  which must match the agent's whole value. The login's value goes to stdin
  only, never into argv. With the example, `vault_pipe(id, "password",
  "docker-login", {"registry": "ghcr.io"})` runs `docker login --username
  <user> --password-stdin ghcr.io`, and `vault_pipe(id, "password",
  "gh-token")` logs `gh` in with a token stored as the login's password. A
  token kept in a custom field goes the same way:
  `vault_pipe {id, custom_field: "token", target: "jira-login", args: {site: "<team>.atlassian.net"}}`
  with a target like `{"argv": ["acli", "jira", "auth", "login", "--site",
  "{arg:site}", "--email", "{username}", "--token"], "args": {"site":
  "[a-z0-9][a-z0-9-]*\\.atlassian\\.net"}}`.
- `make filler-policy-upgrade` upgrades an older policy once (one with no
  `pipe_targets`): it backs it up to `policy-backups/`, gives the
  `all_items` client `manage` with every action on and `"pipe": []`, and
  adds `"pipe_targets": {}`. After that the file is yours: a `manage` you
  remove is not added back. A policy without `backends` gets `"backends":
  {"shared": {"type": "vaultwarden"}}` and `"backend": "shared"` on every
  client (what it already meant, written out). Each step runs once.

## Day to day

All from `selfhost/` (or `browser-stack/`), as prep:

| | |
|---|---|
| `make vault-up` / `make stack-up` | build the image from this tree and (re)start the filler with Vaultwarden (stack-up: and the browser) |
| `make filler-items` | the agent account's logins: name, item id, https hosts |
| `make filler-policy-edit` | back up, edit a copy, validate, swap it in |
| `make filler-lock` | stop the filler; its keys leave memory, and it stays stopped across reboots |
| `make filler-up` | start again (unlocks from the key files) |
| `make filler-restart` / `make filler-logs` | restart; the container's log |
| `make filler-status` / `make vault-status` | container, bind, health (unlocked), tokens |
| `make filler-audit` | recent fills and refusals |
| `make filler-test` | unit tests |
| `make filler-smoke` | end-to-end canary run with a leak sweep, against fakes |

**Adding a login later.** Add it to the agent account's vault, with its https
URL. With `all_items` that is all: it can be used within 15 s. Otherwise add
its `item_id` (from `make filler-items`) under the client in `make
filler-policy-edit`. No re-enroll needed either way.

**Rotation.** If you rotate the agent's API key or encryption key in the web
vault, run `make vault-enroll BACKEND=shared` again. To rotate a client
token: `make vault-tokens ROTATE=1 NAME=bridge-client` (or
`NAME=vault-client`); it issues, takes and restarts the filler. For the bridge
token, restart the bridge too (the vault tools' MCP server reads its token on
every call). A new browser controller token goes over with `make vault-tokens`.

## Limits

- **Known limit: the `docker` group.** prep is in the `docker` group, and
  any account in it (or in `sudo`) is root in effect: it can start a
  container that mounts `/srv/happy-filler` or reads the filler's memory, and
  it runs the filler's admin commands. The filler protects secrets fully only
  from agents with no docker or sudo access (a follow-up: run agents as such a
  user).
- **Known limit: `vault_pipe`.** To feed a command's stdin, the value has to
  reach the agent-side MCP process (`vault-mcp`) for that one call: the filler
  returns it only on the vault token's pipe route, and `lib/pipe.mjs` writes
  it to the child's stdin, scrubs every encoded form of it out of the output
  and drops it. A process running as your user can read the vault token and
  ask for a value through that route, and an allowlisted command could be
  made to print what it read (scrubbed, but only the forms the scrubber
  knows). Allowlist only commands that read a secret from stdin and keep it
  to themselves, and give `pipe` only to the clients that need it.
- With OCR enabled, the controller's text from after an action, its
  `actions.jsonl` and its screenshots can contain a value that is visible on
  the page. That is usually the username, because password fields are masked.
  The bridge scrubs this text before the agent sees it. Copies saved on disk in
  the controller's data directory are not scrubbed.
