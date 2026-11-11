# Browser stack

A real Chromium an agent drives through MCP tools while a person watches it live and can
take control, plus the vault tools and the secret filler that signs it in. It runs on prep-ml.
Any harness can use it, on prep-ml or on a Mac, and any app can embed its live view.

| Folder | What it is |
| --- | --- |
| `browser/` | auto-browser, the per-chat browser pods and their launcher, the live bridge (`browser/bridge`: live view on :6090 plus the `browser_*` MCP server), and the secret filler (`browser/filler`). Details are in `browser/README.md`. |
| `vault-mcp/` | the `vault_*` MCP server (it goes through the filler) |
| `identity/` | how a tool call is matched to its chat: `env.mjs` (the harness's environment), `chatmeta.mjs` (the `_meta` the gateway client stamps), `agentchat.mjs`/`.py` (a Happy Agent daemon's journal) |
| `client/` | `mcp-gateway-client.mjs`, the stdio MCP server a Mac harness runs. It forwards to the LAN gateway. |
| `gateway/` | `gateway-config.py`, which writes this stack's blocks into the host agentgateway config, and a small test MCP server |
| `scripts/` | `mcp-register.py`, which registers the MCP servers with every harness |

Every container runs as its own non-root uid (bridge 1992, controller and launcher 1993,
browser node 1994, docker proxy 1995; the filler 1990, Vaultwarden 1991) with all
capabilities dropped and a read-only root. The launcher reaches docker only through an
allowlisting socket proxy. See "Users and privileges" in `browser/README.md`.

The old `selfhost/browser` and `selfhost/vault-mcp` paths are symlinks to the folders here.
Harness configs that name them keep working. `selfhost/Makefile` includes the make fragments
from this folder, so `make -C selfhost <target>` and `make -C browser-stack <target>` do the
same thing.

## Make targets

```
make help
make browser-up / browser-down / browser-status / browser-logs     (browser.mk)
make browser-bridge-restart [BRIDGE_ENV=1]
make filler-status / filler-install COMMIT=<sha> / ...           (filler.mk)
make mcp-register [DRY=1] [NO_REMOTE=1] / mcp-check               (register.mk)
make gateway-config [WRITE=1] / gateway-keys / gateway-test       (gateway.mk)
make test        every unit suite here
```

The compose project is still `happy-browser`. Data and secrets are in `BROWSER_STACK_HOME`
(default `~/.local/share/happy-browser`; `HAPPY_BROWSER_HOME` is still read).
`browser/.env.browser` holds local overrides and is not committed.

## Names

The generic names are listed first. The older ones are still accepted.

| Use | Also read |
| --- | --- |
| `BROWSER_STACK_HOME`, `BROWSER_STACK_SECRETS` | `HAPPY_BROWSER_HOME`, `HAPPY_BROWSER_SECRETS` |
| `BROWSER_VAULT_MCP_HOME`, `BROWSER_VAULT_FILLER_URL` | `HAPPY_VAULT_MCP_HOME`, `HAPPY_VAULT_FILLER_URL` |
| filler header `X-Client-Chat` | `X-Happy-Chat`. The bridge sends both. A request whose two headers name different chats is refused. |

The MCP server name stays `happy-browser-bridge`.

## The LAN gateway (how the Macs reach it)

The host's agentgateway (`/home/prep/coder/agentgateway/config.yaml`) has a second gateway,
`lan`, on `192.168.2.72:8904`. `127.0.0.1:8903` is the default gateway, and one port cannot
serve two addresses. Every request needs a Mac's own API key
(`Authorization: Bearer`, from `~/.config/browser-stack/gateway-keys/<mac>`) and must come
from that Mac's address. The `lan` gateway serves:

- `/v1/...`: the coder LLM API, the same as on the default gateway.
- `/browser/mcp` and `/vault/mcp`: agentgateway starts `browser/bridge/mcp.mjs` and
  `vault-mcp/mcp.mjs` itself, one per MCP session, with `BROWSER_CHAT_FROM_META=1`.

`make gateway-config` prints a redacted diff and validates it. `WRITE=1` backs the config up to
`/home/prep/happy-trash/<ts>_agentgateway-config/` and writes it. agentgateway reloads it on its
own; only a new listener needs `sudo systemctl restart agentgateway`.

On a Mac, a harness runs
`node client/mcp-gateway-client.mjs --url http://192.168.2.72:8904/browser/mcp`.
The key comes from `~/.config/browser-stack/gateway-key` (mode 600). The client stamps every
`tools/call` with `_meta["browserstack/chat"] = {source, id, forked_from?}`, taken from its own
environment (`HAPPY_SESSION_ID`, `CLAUDE_CODE_SESSION_ID`, `BROWSER_CHAT_ID`). With `--agent-db`
it takes the chat from that Mac's Happy Agent database instead. It replaces anything the
harness put under that key. The servers read it only in `BROWSER_CHAT_FROM_META=1` mode and
refuse a call that has none. Tool arguments never choose a chat. The chat key is unchanged:
`sha256("<source>:<id>")`, first 32 hex characters.

The firewall must admit the Macs to 8904 (root, once):

```
sudo ufw allow proto tcp from 192.168.2.55 to 192.168.2.72 port 8904
sudo ufw allow proto tcp from 192.168.2.56 to 192.168.2.72 port 8904
```

## Embedding the live view

The live view is plain HTTP on the bridge, port 6090. It is served on loopback, and on
`192.168.2.72:6090` for the allowlisted Macs (`browser/README.md`, "LAN listener"). An app
embeds it like this:

- **The chat's link.** `GET /live/chat/<chat_key>` returns `{id, url, live, pod, status, ...}`,
  or 404 when the chat has no browser. `chat_key` is the key above; for a Happy chat it is
  `sha256("happy:" + session id)[:32]`. This is the source of truth for whether a chat shows a
  live browser.
- **The page.** `GET /live/<id>` is a self-contained page that fits a phone. Load it in a web
  view or an iframe. Its parts are also available on their own: `/live/<id>/frame.jpg` (the
  latest frame) and `/live/<id>/state` (`watching | user | takeover | done`, the url and
  title, the last action, and a pending approval).
- **Take control.** `POST /live/<id>/take` returns the state plus `novnc_url`, which is noVNC
  served through the same port (`/live/<id>/vnc/...`, websocket `/live/<id>/vnc/websockify`).
  The password is in the URL fragment. `POST /live/<id>/release` hands control back. `nav`,
  `approve`, `deny`, `end` and `sleep` are described in the header of
  `browser/bridge/lib/app.mjs`.
- **Origin.** Absolute URLs returned on the LAN listener use `http://192.168.2.72:6090`
  (`BRIDGE_LAN_PUBLIC_BASE`). URLs returned on loopback use `BRIDGE_PUBLIC_BASE` (default
  `http://localhost:6090`). The LAN listener answers only to its own `Host` and serves no
  `/api/*`.
- The link id (128 random bits) is the capability. Anyone who has it can watch and take
  control, so show it only to the chat's owner.
