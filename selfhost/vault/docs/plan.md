I've designed a self-hosted Vaultwarden plus a separate "secret-filler" service on prep-ml. Nothing was changed, but I need to report a slip first.

## Read this first
1. **I printed one live secret.** A `docker exec … env` with a broken redaction filter put the controller's `SHARE_TOKEN_SECRET` into my tool output. I have not repeated it. Rotate it: move `~/.local/share/happy-browser/secrets/share-token-secret` to `~/trash/`, then run `make browser-init browser-down browser-up`.
2. **Agents can already skip the bridge.** `~/.claude.json` has a global `auto-browser` MCP entry (`http://127.0.0.1:8010/mcp` with an `Authorization` header). Any agent that uses it goes straight past every guard in `mcp.mjs`. It has to be removed before guards in `mcp.mjs` mean anything.
3. **What the guards actually stop.** The controller token is readable by uid 1000 in two places: `secrets/api-token` and `data/api-token`. So until Phase 6 (below), the guards stop secrets reaching the model through tool results, logs and prompt injection. They do not stop a hostile uid-1000 process calling the controller's REST API directly. Phase 6 closes that for uid 1000; nothing closes it for docker.

## What I checked (auto-browser 1.14.0, inside the controller image)
- **Traces are off.** `ENABLE_TRACING` defaults to false (`app/config.py:255`), and the trace only starts `if enable_tracing` (`session_creation.py:133`). When on, it records screenshots and DOM snapshots, and the typing calls one `page.keyboard.type(char)` per character (`actions.py:923`), so a trace would hold the typed value. Pin `ENABLE_TRACING=false` anyway.
- **Request bodies are captured.** `NETWORK_INSPECTOR_CAPTURE_BODIES` defaults to true (`config.py:397`), so a login POST body holding the password lands in `/sessions/{id}/network-log`. The PII scrubber is generic and can't be relied on for this. Set it to false.
- **`sensitive:true` works.** The text is replaced with `text_redacted` in the action record. Approvals keep only an HMAC of it, the witness log redacts `text`, `text_preview` and `totp_secret`, and the script export writes `<REDACTED>`.
- **Frames.** Element ids belong to the main document's isolated world. Elements inside a cross-origin frame are never addressable, so the target's frame origin should equal the top-level origin (to confirm, see empirical check 2).
- **No eval endpoint over REST.** Typing is `POST /sessions/{id}/actions/type`, and `GET /sessions/{id}` gives the URL.
- **Caddy.** It runs as `prep` from `/home/prep/caddy/Caddyfile`, which is owned by `prep`. The file has site blocks per subdomain (`minio.`, `plex.`, `happy.` …). `vault.girthbass.duckdns.org` already resolves (DuckDNS answers for any subdomain).
- **Free ports.** 8222 and 6091 are free on 127.0.0.1.
- **happy-agent container.** uid 1000, host network, `/home/prep` mounted read-write, no docker socket.
- **Image.** The current Vaultwarden release is `vaultwarden/server:1.37.5-alpine` (2026-11-01). Its digest on Docker Hub is `sha256:bbe684a02d6b0db54256ff88eac9754f4519284a7b26314afc241fd7d0918191`; confirm with `docker buildx imagetools inspect` before pinning.

## Architecture
```
phone / desktop Bitwarden app ──https──> Caddy :443  vault.girthbass.duckdns.org ──> 127.0.0.1:8222 vaultwarden (uid 1991, /srv/happy-vault)
agent ─stdio─> mcp.mjs (uid 1000, never holds values)
   ├─ names only, bearer + X-Happy-Chat ──> 127.0.0.1:6091 secret-filler (uid 1990, /srv/happy-filler)
   │                                          ├─ http://127.0.0.1:8222  API-key login, /api/sync, decrypts in memory
   │                                          └─ http://127.0.0.1:8010  REST type with sensitive:true (its own copy of the controller token)
   └─ pass-through ──> controller /mcp  (taint check and scrub go through the filler first)
```

### Choices (one each)
- **Reaching Vaultwarden from the apps: a subdomain, `vault.girthbass.duckdns.org`.** Do not use a subpath. A subpath would put the web vault on the same origin as the other apps on `girthbass.duckdns.org`, so a bug in any of them could reach the vault's browser storage. No new port is opened.
  - Caddy returns 404 for `/admin*`.
  - The admin panel is reachable only at `http://127.0.0.1:8222/admin`, and only while `ADMIN_TOKEN` is set.
- **How the filler reads secrets: the Vaultwarden API directly, decrypted with `node:crypto`. No `bw` CLI and no `bw serve`.**
  - `bw serve` exposes the unlocked vault over HTTP with no auth. The filler needs host networking to reach the controller, so it would land in the host network namespace.
  - `bw` per call costs 1–2 s, a large Node dependency tree, and handling `BW_SESSION`.
  - Direct API: a sync is tens of ms over loopback, decryption takes microseconds, there are zero dependencies (like the bridge), and TOTP is RFC 6238 with HMAC.
  - Flow:
    1. `POST /identity/connect/token` with `grant_type=client_credentials`, `scope=api`, `client_id=user.<uuid>`, `client_secret`, plus a fixed device id and name.
    2. `GET /api/sync?excludeDomains=true`.
    3. Decrypt `profile.key` (EncString type 2, AES-256-CBC with HMAC-SHA256, MAC checked before decrypting) using the stored user key.
    4. Decrypt `profile.privateKey` (PKCS8).
    5. Decrypt each organization key (type 4, RSA-OAEP-SHA1), if the account is in any. In the chosen setup it is in none.
    6. Decrypt the item key, if the cipher has one, with the user key (personal item) or its organization's key.
    7. Decrypt `login.username`, `password`, `totp` and `uris[].uri` with that key.
  - Any other EncString type fails closed.
- **Unlock key storage: store the decrypted 64-byte user key, not the master password.**
  - `make filler-enroll` runs once, interactively, in a one-shot container as uid 1990. It reads the email and master password from the TTY, does prelogin and PBKDF2-SHA256, stretches with HKDF (`enc`/`mac`), decrypts the user key, writes `vault-user-key`, and throws the password away.
  - Day to day the filler holds only the API key and the user key. Neither can change the master password or log into the web vault.
  - The agent account must use PBKDF2: Node 22 has no Argon2.
- **Cache and sync:** the filler syncs on each fill or list if the last sync is more than 15 s old, and keeps everything in memory only. No websocket or push.
- **Restart:** the filler unlocks itself from the 0400 key files at start. `make filler-lock` stops it.
  - Reasoning: anyone who can read uid 1990's files (root or docker) can read its memory too. Unlocking by hand on every restart would not reduce exposure.
- **Where the agent's logins live: the personal vault of a dedicated account, `agent@vault.girthbass.duckdns.org`. No organization** (decided 2026-11-05).
  - The account holds only logins agents may use. Your own vault is a different account, so the filler cannot read any of your items.
  - You add and edit the agent's logins by logging in as the agent account (Bitwarden app or web vault).
  - The filler may read any cipher the account can decrypt. Isolation between clients is the root-owned `policy.json` alone: a chat reaches only the item ids its client lists, and an item id may be listed by one client only. The vault itself does not separate clients.
  - Superseded: one organization per client with an "Agents" collection, and a filler check on `organizationId` and `collectionIds`. A policy that still has `org_id` or `collection_id` is refused.
- **Chat to client:**
  - `mcp.mjs` sends `X-Happy-Chat` from its process environment (`HAPPY_SESSION_ID`, which happy-cli must pass to MCP children; see empirical check 6), never from tool arguments.
  - `policy.json` maps each chat to a client.
  - An unbound chat is refused.
  - An auto-browser session is bound to one (chat, client) at its first fill; a fill for another client in that session is refused.
  - Limit: uid-1000 code asserts the chat id. This stops confusion and prompt injection, not a hostile local process.

## Vaultwarden settings
- **Image:** `vaultwarden/server:1.37.5-alpine@sha256:bbe684a0…` (verify first).
- **Data:** `/srv/happy-vault/data`, owned by uid 1991, mode 0700.
- **Backups:** `/srv/happy-vault/backups/vault-<UTC ts>.tar.zst`, keeping 30.
  - Each backup holds a SQLite snapshot, `attachments/`, `rsa_key*` and `config.json`.
  - `/home/prep` is never used: `rsa_key.pem` signs login tokens.
  - The disk is 95% full, but the vault is tiny.
- **`ADMIN_TOKEN`:** the Argon2 PHC string from `vaultwarden hash`, kept in `/srv/happy-vault/vaultwarden.env` (root:1991, 0640). `make vault-admin-off` removes it after setup, which turns `/admin` off.
- **Sign-ups:** `SIGNUPS_ALLOWED=false` and `INVITATIONS_ALLOWED=true`, with no SMTP. An invited email can register directly.
- **Org creation:** `ORG_CREATION_USERS` is your email, set in the env file. No organization is used; this only stops the agent account from creating one.
- **The env file is read by Vaultwarden, not by compose.** It is mounted read-only at `/etc/vaultwarden.env` and named by `ENV_FILE`; Vaultwarden loads it into its own process at start (the log says `Using environment file /etc/vaultwarden.env`). So `docker exec … printenv` never shows these values, because an exec'd process gets only the compose `environment:`. `make vault-status` reports from the mounted file whether each key is set, never its value.
- **Other settings:** `DOMAIN=https://vault.girthbass.duckdns.org`, `ROCKET_PORT=8222`, `IP_HEADER=X-Real-IP`, `PUSH_ENABLED=false`, `SENDS_ALLOWED=false`, `EMERGENCY_ACCESS_ALLOWED=false`, `PASSWORD_HINTS_ALLOWED=false`, plus the login rate limits.
- **Websocket notifications** run on the main port (`/notifications/hub`), and Caddy proxies them as is.
- **Phone:** in the Bitwarden iOS app, choose self-hosted with server URL `https://vault.girthbass.duckdns.org`. Without push, pull to refresh.
- **2FA** on both accounts. API-key login skips 2FA by design.

### `selfhost/vault/compose.vault.yml`
```yaml
name: happy-vault
services:
  vaultwarden:
    image: vaultwarden/server:1.37.5-alpine@sha256:bbe684a02d6b0db54256ff88eac9754f4519284a7b26314afc241fd7d0918191
    user: "1991:1991"
    restart: unless-stopped
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    ports: ["127.0.0.1:8222:8222"]
    environment:
      ENV_FILE: /etc/vaultwarden.env    # ADMIN_TOKEN (setup only), ORG_CREATION_USERS; mounted below
      DOMAIN: https://vault.girthbass.duckdns.org
      ROCKET_PORT: "8222"
      DATA_FOLDER: /data
      SIGNUPS_ALLOWED: "false"
      INVITATIONS_ALLOWED: "true"
      PASSWORD_HINTS_ALLOWED: "false"
      SHOW_PASSWORD_HINT: "false"
      SENDS_ALLOWED: "false"
      EMERGENCY_ACCESS_ALLOWED: "false"
      PUSH_ENABLED: "false"
      IP_HEADER: X-Real-IP
      LOGIN_RATELIMIT_SECONDS: "60"
      LOGIN_RATELIMIT_MAX_BURST: "5"
      ADMIN_RATELIMIT_SECONDS: "300"
      ADMIN_RATELIMIT_MAX_BURST: "3"
      LOG_LEVEL: warn
    volumes: ["/srv/happy-vault/data:/data"]
```

### Caddy block (insert after `happy.girthbass.duckdns.org {…}`)
Back up first using the existing `Caddyfile.backup.<epoch>` convention, then `caddy validate`, then `caddy reload`.
```
vault.girthbass.duckdns.org {
    tls { protocols tls1.2 tls1.3 }
    @admin path /admin /admin/*
    respond @admin 404
    header { Strict-Transport-Security "max-age=31536000"; X-Robots-Tag "noindex, nofollow"; -Server }
    reverse_proxy 127.0.0.1:8222 { header_up X-Real-IP {remote_host} }
}
```

### Controller changes (`selfhost/browser/compose.browser.yml`, controller `environment`)
```yaml
      ENABLE_TRACING: "false"                    # traces record keystroke params and DOM snapshots
      NETWORK_INSPECTOR_CAPTURE_BODIES: "false"  # a login POST body holds the password
```

## The filler service: `selfhost/browser/filler/` (zero dependencies, node:test)
- **Files:**
  - `server.mjs`
  - `lib/config.mjs`
  - `lib/vaultcrypto.mjs`: EncString types 2 and 4, PBKDF2, HKDF, item keys
  - `lib/vault.mjs`: token, sync, decrypt, 15 s cache
  - `lib/totp.mjs`: RFC 6238 and `otpauth://` with SHA1/256/512, digits and period. If fewer than 3 s are left in the period, it waits for the next code.
  - `lib/policy.mjs`
  - `lib/hosts.mjs`
  - `lib/fill.mjs`
  - `lib/taint.mjs`
  - `lib/scrub.mjs`
  - `lib/audit.mjs`
  - `lib/controller.mjs`: REST client with the controller token
  - `enroll.mjs`
  - `compose.filler.yml`
  - `test/*`
- **HTTP API** on 127.0.0.1:6091.
  - Requires `Authorization: Bearer <filler-client-token>`. The filler stores only its SHA-256, in `secrets/client-token.sha256`.
  - Only `Host` 127.0.0.1 or localhost is accepted, otherwise 421.
  - `X-Happy-Chat` carries the chat.
- **Routes:**
  - `POST /v1/list` → `{client, secrets:[{name:"github.password", hosts:["github.com"], kind:"password"}…]}`
  - `POST /v1/fill {session_id, element_id, name}` → `{ok, kind, host}`
  - `POST /v1/login {session_id, site}` → `{status:"submitted"|"totp_submitted"|"needs_human", host}`
  - `POST /v1/session {session_id?}` → `{tainted, any_tainted, drop_images}`
  - `POST /v1/scrub {payload}` → `{payload}`: scrubs with the values of every tainted session
  - `GET /healthz` → `{ok, unlocked, sync_age_s}`: no names
- **`policy.json`** lives at `/srv/happy-filler/policy.json` (root:1990, 0640).
  - The filler refuses to start if the file is group- or world-writable or not owned by root.
  - Shape: `{version:1, clients:{acme:{secrets:{github:{item_id, hosts:["github.com"], fields:["username","password","totp"]}}}}, chats:{"<happy session id>":"acme"}}`
- **Fill guards, in order:**
  1. Name to item through the policy only (each item id belongs to one client); the item is read from the agent account's vault.
  2. Allowed hosts are the intersection of the item's URI hostnames (https only) and the policy's hosts. Matching is exact and case-folded after punycode. No suffix match, no userinfo, default port only.
  3. Before typing, `GET /sessions/{id}` must show `https:` and an allowed host. The frame origin must equal the top origin (see empirical check 2).
  4. Field kind comes from the element's attributes (empirical check 1):
     - password: `type=password`, or `autocomplete` `current-password` / `new-password`
     - username: `type` in text/email/tel and not password
     - totp: `autocomplete=one-time-code`, or a numeric input whose name, id or label says otp, code, totp or 2fa
  5. `POST /actions/type {element_id, text, sensitive:true, clear_first:true}`. The response body is discarded.
  6. Then `GET /sessions/{id}` again. If the host changed, the fill is recorded in the audit as `host_changed`, the result is an error, and the session stays tainted.
  7. Taint the session, record the value in memory for scrubbing, and set `drop_images` if the kind is not password.
  8. Poll the session. Once it is closed or 404, drop its values after a 10-minute grace period.
- **`login(site)`** runs up to 3 steps (handles username-then-password pages). Each step:
  1. Observe.
  2. Pick the fields itself.
  3. Fill username, then password.
  4. Press Enter.
  5. Wait.
  6. If a one-time-code field appears and the item has a TOTP, type the current code the filler computed.
- **Scrub:** walks every string in the result, `error.message` included. Each filled value is replaced by `[secret:<name>]` in these forms:
  - plain
  - `encodeURIComponent` and form encoding (`+`)
  - base64, standard and url-safe, at all 3 alignments (covers `user:pass` Basic auth)
  - JSON-escaped and double JSON-escaped
  - HTML-entity escaped
  - For sessions with `drop_images`, image blocks are replaced by a text note.
- **Audit:** `/srv/happy-filler/audit/YYYY-MM.jsonl`, one line per fill: `{ts, chat, client, session, name, host, field_kind, outcome}`. Never values. Owned 1990, mode 0640, group prep.

### Directory layout under `/srv/happy-filler` (outside `/home/prep`, so uid 1000 cannot write it)
- `releases/<git-sha>/{app,compose.filler.yml}`: owned by root, read-only; `current` points to the active release.
  - `make filler-install COMMIT=<sha>` fills it from `git archive`. The source in `/home/prep` is writable by agents, so only a commit you have reviewed is deployed.
- `secrets/`: owned 1990, mode 0500; files 0400. Contains `vault-client-id`, `vault-client-secret`, `vault-user-key`, `vault-device-id`, `vault-email`, `controller-token`, `client-token.sha256`.
- `state/taint.json`
- `audit/`

### `compose.filler.yml`
```yaml
name: happy-filler
services:
  filler:
    image: node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914
    user: "1990:1990"
    network_mode: host
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    ulimits: { core: 0 }
    restart: unless-stopped
    command: ["node", "/app/server.mjs"]
    environment: { FILLER_HOST: 127.0.0.1, FILLER_PORT: "6091", VAULT_URL: "http://127.0.0.1:8222", AUTO_BROWSER_URL: "http://127.0.0.1:8010", FILLER_HOME: /filler }
    volumes:
      - /srv/happy-filler/current/app:/app:ro
      - /srv/happy-filler/secrets:/filler/secrets:ro
      - /srv/happy-filler/policy.json:/filler/policy.json:ro
      - /srv/happy-filler/state:/filler/state
      - /srv/happy-filler/audit:/filler/audit
```

## Changes to `mcp.mjs` and the bridge config
- **Config** (`lib/config.mjs`): `fillerUrl` (default `http://127.0.0.1:6091`) and `files.fillerToken` = `secrets/filler-client-token`, created by `browser-init`.
- **New tools:**
  - `browser_list_secrets()`: names, hosts and kinds only.
  - `browser_fill_secret(session_id, element_id, name)`
  - `browser_login(session_id, site)`
- **Always refused:** `totp_secret` and `totp_hosts` in `browser_create_session`.
- **Refused while `any_tainted`** (or on the tainted session, when a `session_id` is given):
  - `browser_eval_js`
  - `browser_get_html` unless `text_only` is true
  - `browser_find_elements` / `browser_wait_for_selector` with a selector matching `/\[\s*value\b/i`
  - `browser_fork_session`
  - `browser_save_auth_profile`
  - `execute_action` press of `Control+c`, `Meta+c`, `Control+x`, `Meta+x` or `Control+Insert`
  - `execute_action` navigate to a non-`https:`/`http:` scheme (`javascript:`, `data:`, `view-source:`, `chrome:`)
- **Scrubbing:** when anything is tainted, every pass-through result goes through `/v1/scrub` before it reaches the agent.
- **Filler unreachable:** if the filler-client-token file exists, the call fails closed with an error.

## Make targets: new `selfhost/vault.mk`, added with `-include vault.mk` in `selfhost/Makefile`
- **Vault:**
  - `vault-init` (sudo, one time): creates `/srv/happy-vault` and the env file, prints no secrets
  - `vault-up`, `vault-down`, `vault-logs`
  - `vault-status`: fails if 8222 is bound anywhere but 127.0.0.1
  - `vault-admin-on` (interactive hash), `vault-admin-off`
  - `vault-caddy-apply`: back up, insert block, validate, reload
  - `vault-backup` (versioned tarball), `vault-restore-check` (restores the latest backup into a temporary container and counts ciphers)
- **Filler:**
  - `filler-install COMMIT=`
  - `filler-init`: client token, controller-token copy, policy skeleton
  - `filler-enroll`
  - `filler-up`, `filler-down`, `filler-lock`, `filler-status`, `filler-logs`
  - `filler-policy-edit`: `sudoedit`, then `node … --check-policy`
  - `filler-audit`
  - `filler-test`: `node --test`
  - `filler-smoke`
- Add 6091 and 8222 to `BROWSER_PORTS`.

## Tests (node:test)
- **Fakes:**
  - `filler/test/fake-vaultwarden.mjs`: prelogin, `connect/token`, `/api/sync`. Fixtures are encrypted in the test with `node:crypto`: an RSA org key, items with and without an item key, two orgs.
  - `fake-controller.mjs`: sessions, attribute-carrying observe, records `type` calls and asserts `sensitive:true`, can navigate in the middle of a type.
- **Filler tests:**
  - `crypto.test`: EncString round trips, MAC tamper rejected, unknown type rejected.
  - `totp.test`: RFC 6238 vectors for SHA1/256/512.
  - `policy.test`: exact host matching against `evilgithub.com`, `github.com.evil.com`, `https://github.com@evil.com`, http, port, IDN; chat to client; cross-client refusal; policy permissions.
  - `scrub.test`: every encoding and alignment, nested values and errors, images dropped.
  - `fill.test`: wrong kind refused, host checks before and after, the TOTP code typed matches, a grep of the audit and logs finds no value or variant.
- **Bridge test:** `bridge/test/secrets.test.mjs` with a fake filler. Covers: the chat comes from env, not args; every refusal above; scrubbing applied; fail closed when the filler is down; `totp_secret` refused.
- **`filler-smoke`:**
  - Runs a separate filler instance with `FILLER_TEST_ALLOW_LOOPBACK_HTTP=1` against a local login page, using a canary item.
  - Asserts the canary appears in no MCP result. Also greps controller `data/` (audit, events, artifacts, sessions), filler logs and bridge logs for the canary.
  - This is the empirical check on traces and recordings.

## Phases (one commit per numbered step)
1. **Leaks closed in the controller.** In compose: `ENABLE_TRACING=false`, `NETWORK_INSPECTOR_CAPTURE_BODIES=false`. Operations, not committed: rotate share-token-secret; remove `auto-browser` from `~/.claude.json`.
2. **Vaultwarden.** Add `compose.vault.yml`, the vault targets in `vault.mk`, and a README section. Then by hand:
   1. Apply the Caddy block.
   2. Create your account (admin on), then turn admin off.
   3. Invite and register the agent account (PBKDF2-SHA256), and add the logins agents may use to its own vault.
   4. Create its API key.
3. **Filler core.** `vaultcrypto`, `vault`, `totp`, `policy`, `hosts`, `scrub`, the fake Vaultwarden, and their tests.
4. **Filler service.** `server.mjs`, the fill and login flows, taint, audit, the fake controller, `compose.filler.yml`, and the filler targets.
5. **`mcp.mjs` integration.** The 3 tools, the guards, scrubbing, the chat header, and tests.
6. **happy-cli.** Pass `HAPPY_SESSION_ID` into the environment of spawned MCP servers (`packages/happy-cli/src/claude/claudeLocal.ts` env, and the codex/gemini/acp equivalents).
7. **`filler-smoke`** canary and leak sweep.
8. **Custody (recommended).**
   - Move `HAPPY_BROWSER_HOME` to `/srv/happy-browser` with a service uid. The controller token, `data/` (which includes `api-token`, artifacts, `browser-profile` and the Playwright endpoint file) and `links.json` must not be readable by uid 1000.
   - The bridge runs as that uid.
   - `mcp.mjs` pass-through goes through a filler `/v1/mcp` gate that applies taint and scrub itself.
   - After this, uid-1000 processes cannot bypass the guards.

## Risks that remain
- **The docker group and sudo are root.** prep is in both, so any host agent session with docker can read `/srv`, `docker exec` into the filler and read its memory, and remount anything. The guarantees hold only for agents without docker, such as happy-agent (no socket), and fully only after step 8.
- **Dotfiles.** happy-agent has `/home/prep` mounted read-write. It can edit `~/.bashrc`, user systemd units or the Caddyfile, and get code run later by your docker-capable shell. That is a path to escalate.
- **Caddy runs as uid 1000.** A modified Caddyfile could serve a malicious web vault and capture your master password. Use the native apps; open the web vault only when you must.
- **Race during typing.** The page can navigate during the controller's per-character typing. The check after the fill detects it, but the characters may already have gone to the new page.
- **Leftovers before step 8:**
  - After-action screenshot artifacts in `data/artifacts` show non-password secrets and are readable by uid 1000.
  - Bridge frames (`/live/<id>/frame.jpg`) can be fetched by anyone who can read `links.json`.
- **Chat identity** is asserted by uid-1000 code (stated above).
- **Stored key.** The user key on disk is as strong as uid 1990's privacy, and anyone with root or docker has it. Rotation:
  - Rotate the agent API key in the web vault, then run `filler-enroll`.
  - Rotating the agent's encryption key also needs `filler-enroll`.
  - To revoke one login, delete it from the agent account's vault or remove it from the policy. To revoke everything, `make filler-lock` and rotate the agent's API key.
- **One vault for every client.** All client logins sit in the same personal vault, so a wrong `item_id` in the policy would hand one client's login to another client's chats. The policy is root-owned and an item id may appear under one client only, but a typo is not caught.
  - Rotate `filler-client-token` with `filler-init` and a restart.

## Empirical checks still open
1. Does the REST observe interactable carry `type`, `autocomplete` and `name` for each element id? If not, the filler builds its own selectors (one visible `input[type=password]`, and so on), and the agent's element id only picks between matches.
2. Can an element id ever point into a cross-origin iframe (for example an embedded Okta or Stripe login)?
3. Does Chromium keep a "Login Data" file or show a save-password prompt in `/data/profile` for Playwright `new_context`?
4. Does an accessibility snapshot or observe show the value of text inputs? (Scrubbing covers it either way.)
5. Vaultwarden 1.37.5:
   - the `vaultwarden backup` subcommand
   - running `read_only` as a non-root user
   - API-key login
   - item keys
   - whether any EncString type other than 2 or 4 appears in sync
6. What happy-cli's MCP child processes actually see in their environment (the name of the session-id variable).
7. Caddy gets a certificate for `vault.` over HTTP-01.
8. The image digest via `docker buildx imagetools inspect`.

### Critical Files for Implementation
- /home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser/bridge/mcp.mjs
- /home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser/compose.browser.yml
- /home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser/bridge/lib/config.mjs
- /home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser.mk (model for the new `selfhost/vault.mk`)
- /home/prep/caddy/Caddyfile (add the `vault.` block) and /home/prep/.claude.json (remove the direct `auto-browser` MCP entry)
