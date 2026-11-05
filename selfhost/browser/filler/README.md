# Secret filler

The browser agent logs in to client sites without ever seeing a password,
username or one-time code. It asks for a secret by name (`github.password`),
and this service checks the request, reads the value from Vaultwarden and types
it into the agent's browser session itself. The value is never returned, and
any copy of it that turns up in a later tool result is replaced with
`[secret:github.password]`.

- Runs as uid 1990 from `/srv/happy-filler/current`, which is a reviewed git
  commit (not the working tree), and listens only on `127.0.0.1:6091`.
- Logs in to the vault with the agent account's API key and user key. It never
  holds the master password.
- Reads the **personal vault of the agent account**
  (`agent@vault.girthbass.duckdns.org`). There is no organization: that
  account holds only the logins agents may use, and your own account stays
  separate. A chat reaches an item only through a name its client lists in the
  root-owned policy, and an item may be listed by one client only.
- Types a value only into a field of the right kind, only on a page that is
  https on a host that appears both in the vault item's URIs and in the policy,
  and only into a session bound to the same chat and client.
- Audit log: `/srv/happy-filler/audit/YYYY-MM.jsonl` records names, hosts and
  outcomes. It never records values. Read it with `make filler-audit`.

The design and its limits are in `selfhost/vault/docs/plan.md`.

## Setup (once)

These steps come after the vault is up (`selfhost/vault/README.md`).

1. **Register the agent account.** `agent@vault.girthbass.duckdns.org` is
   invited on the server (sign-ups are closed, so only an invited email can
   register). At `https://vault.girthbass.duckdns.org` choose **Create
   account** with that email and a long random master password; keep the
   password in your own vault. Its KDF must be **PBKDF2-SHA256** (Settings >
   Security > Keys > Encryption key settings); the filler refuses Argon2id.
2. **Add the agent's logins.** Log in as the agent account (Bitwarden app or
   web vault) and add each login agents may use, with its https URL and,
   if wanted, its TOTP seed (Authenticator key). Nothing else goes in this
   vault.
3. **Note its API key:** Settings > Security > Keys > **View API key**, the
   `client_id` (`user.<uuid>`) and `client_secret`.
4. `make filler-init` (sudo): directories, the bridge's client token, and an
   empty policy.
5. `make filler-install COMMIT=<sha>` (sudo): deploy the commit you reviewed.
6. `make filler-enroll` (sudo, interactive): type the agent's email, the API
   key and the master password. Only the API key and the derived user key are
   stored, as 0400 files.
7. `make filler-policy-edit` (sudo): bind clients, secrets and chats (see below).
8. `make filler-up`, then `make filler-status`.

## Policy: `/srv/happy-filler/policy.json` (root:1990 0640)

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

- `item_id` is the login's uuid in the agent account's vault. Open the item in
  the web vault (logged in as the agent): the URL ends in `itemId=<item_id>`.
- `org_id` and `collection_id` belonged to an earlier, organization-based
  design. A policy that still has them is refused.
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

### Every chat shares the agent's logins

```json
{"version":1,"default_client":"agent","clients":{"agent":{"secrets":{"<name>":{"item_id":"<uuid>","hosts":["example.com"],"fields":["username","password","totp"]}}}},"chats":{}}
```

The trade-off: any chat, including Happy Agent chats and any other process
holding the bridge's client token, can ask for a fill of any of these logins,
so there is no separation between chats any more. What still holds: values
never reach the model (the filler types them and every result is scrubbed),
a value is typed only on an https page on a host that both the vault item and
the policy list, only into a field of the right kind, and a browser session
that holds one chat's secret refuses fills for another chat. To give one
client's chats their own logins later, add that client and its chats; mapped
chats never fall back to the default.

## Day to day

| | |
|---|---|
| `make filler-status` | release, container, bind, health |
| `make filler-lock` | stop the filler; its keys leave memory |
| `make filler-up` | start again (unlocks from the key files) |
| `make filler-audit` | recent fills and refusals |
| `make filler-test` | unit tests |
| `make filler-smoke` | end-to-end canary run with a leak sweep, against fakes |

**Adding a login later.** Add it to the agent account's vault, then add its
`item_id` under the client in `make filler-policy-edit`. No re-enroll needed.

**Rotation.** If you rotate the agent's API key or encryption key in the web
vault, run `make filler-enroll` again. To rotate the bridge's client token, run
`make filler-init FILLER_ROTATE=1`, then `make filler-up` and restart the
bridge.

## Limits

- Any account in the `docker` or `sudo` group can read `/srv`, run
  `docker exec` in the filler, and read its memory. The filler protects
  secrets only from agents that have no docker or sudo access.
- With OCR enabled, the controller's text from after an action, its
  `actions.jsonl` and its screenshots can contain a value that is visible on
  the page. That is usually the username, because password fields are masked.
  The bridge scrubs this text before the agent sees it. Copies saved on disk in
  the controller's data directory are not scrubbed.
