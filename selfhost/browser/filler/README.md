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
- Decrypts an item only if it is in the chat's client organization and that
  organization's **Agents** collection.
- Types a value only into a field of the right kind, only on a page that is
  https on a host that appears both in the vault item's URIs and in the policy,
  and only into a session bound to the same chat and client.
- Audit log: `/srv/happy-filler/audit/YYYY-MM.jsonl` records names, hosts and
  outcomes. It never records values. Read it with `make filler-audit`.

The design and its limits are in `selfhost/vault/docs/plan.md`.

## Setup (once)

These steps come after the vault is up (`selfhost/vault/README.md`).

1. **One organization per client** in the web vault
   (`https://vault.girthbass.duckdns.org`), each with a collection named
   `Agents`. Put only the logins the agent may use in `Agents`.
2. **The agent account.** Invite `agent@vault.girthbass.duckdns.org` to each
   client organization as a *User* with **Can view** on `Agents` only. No other
   collection, and not *Can view, except passwords*, because the filler has to
   read the password. Register the account with a long random master password
   and set its KDF to **PBKDF2-SHA256** (Account settings > Security > Keys);
   the filler refuses Argon2id. Then confirm the member in each organization.
   Under Account settings > Security > Keys > **View API key**, note the
   `client_id` and `client_secret`.
3. `make filler-init` (sudo): directories, the bridge's client token, and an
   empty policy.
4. `make filler-install COMMIT=<sha>` (sudo): deploy the commit you reviewed.
5. `make filler-enroll` (sudo, interactive): type the agent's email, the API
   key and the master password. Only the API key and the derived user key are
   stored, as 0400 files.
6. `make filler-policy-edit` (sudo): bind clients, secrets and chats (see below).
7. `make filler-up`, then `make filler-status`.

## Policy: `/srv/happy-filler/policy.json` (root:1990 0640)

```json
{
  "version": 1,
  "clients": {
    "acme": {
      "org_id": "<organization uuid>",
      "collection_id": "<its Agents collection uuid>",
      "secrets": {
        "github": { "item_id": "<item uuid>", "hosts": ["github.com"], "fields": ["username", "password", "totp"] }
      }
    }
  },
  "chats": { "<happy session id>": "acme" }
}
```

- The web vault URL shows the uuids: `…/#/organizations/<org_id>/vault?collectionId=<collection_id>&itemId=<item_id>`.
- `hosts` must also appear as https URIs on the vault item. Matching is exact:
  `github.com` does not allow `www.github.com`.
- A chat with no entry in `chats` can use no secrets. There is no default.
- An item, or an organization, may belong to only one client.
- The filler reloads the policy whenever the file changes. While the file is
  invalid, every fill is refused.

## Day to day

| | |
|---|---|
| `make filler-status` | release, container, bind, health |
| `make filler-lock` | stop the filler; its keys leave memory |
| `make filler-up` | start again (unlocks from the key files) |
| `make filler-audit` | recent fills and refusals |
| `make filler-test` | unit tests |
| `make filler-smoke` | end-to-end canary run with a leak sweep, against fakes |

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
