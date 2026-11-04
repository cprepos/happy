# Live browser for agents

An agent drives a real, headful Chromium. You watch it, or take control, from
the native iOS app. The app's in-app browser sends every request, including
ones to `localhost`, through the Happy Agent workspace proxy. So everything here
binds to `127.0.0.1` only. There is no public port, no Caddy route and no tunnel.

| Piece | Port (127.0.0.1) | What |
|---|---|---|
| auto-browser `browser-node` | 6080 | Xvfb + Chromium + noVNC (password required) |
| auto-browser `controller` | 8010 | REST API + MCP at `/mcp` (Streamable HTTP, bearer token) |
| live `bridge` (`bridge/`) | 6090 | phone page `/live/<id>`, frames, state, takeover hand-back; plus a stdio MCP server |

auto-browser is [LvcidPsyche/auto-browser](https://github.com/LvcidPsyche/auto-browser)
(MIT). We run its published GHCR images for v1.14.0, pinned by digest. Their OCI
revision label is commit `38377f1f04660446feb3e000b8134635f384dac5`.
`seccomp/chromium-sandbox.json` is vendored unchanged from that commit.

## Make targets (from `selfhost/`)

```
make browser-init     # secrets -> ~/.local/share/happy-browser/secrets (600); idempotent
make browser-up       # start, waits for healthy
make browser-status   # containers + health, listening binds (fails if not 127.0.0.1), /healthz
make browser-verify   # MCP 401 without token, tools/list with it; noVNC refuses "no auth"
make browser-logs     # BROWSER_SVC=controller for one service
make browser-down     # stop; data and secrets are kept
make browser-bridge-test    # bridge unit tests (node:test, auto-browser mocked)
make browser-bridge-smoke   # end to end on the running stack; makes and deletes one session
```

## Files on disk

`~/.local/share/happy-browser/` has mode 700:

- `secrets/` (700, every file 600):
  - `api-token`: the controller bearer token;
  - `vnc-password`: 8 characters, since VNC ignores the rest;
  - `bridge-token`;
  - `auth-state-key`: a Fernet key. Saved logins are always encrypted (`REQUIRE_AUTH_STATE_ENCRYPTION=true`);
  - `share-token-secret`;
  - `browser.env`: the compose env-file, rebuilt from the files above;
  - `happy-agent.env`: `AUTO_BROWSER_TOKEN=…` for the Happy Agent container.
- `bridge/links.json` (600): live links (id, session, status, url, title, timestamps). No tokens.
- `data/`: the controller's `/data`, holding artifacts, audit, sessions and auth.
  - `data/browser-profile` and `data/downloads` belong to browser-node's uid 10001 and must stay mode 755.

Tunables, such as screen size, ports and `MAX_SESSIONS`, go in
`selfhost/browser/.env.browser` (gitignored). Start from `.env.browser.example`.

## Settings worth knowing

- **Screen:** Xvfb is 480x1040 and the page viewport is 480x950. This is phone-shaped, so sites
  serve narrow layouts and noVNC is legible on an iPhone. The takeover URL is
  `http://localhost:6080/vnc.html?autoconnect=true&resize=remote`.
- **`ALLOWED_HOSTS=*`:** agents can go anywhere. Because of that the controller has to run with
  `APP_ENV=development`, since production mode refuses `*`. Chromium runs in browser-node's own
  network namespace, so its `127.0.0.1` is not this machine's. Services on this machine that
  bind 0.0.0.0 or the LAN are still reachable from it.
- **`MAX_SESSIONS=3`:** all sessions share one browser desktop, which is auto-browser's "shared"
  mode. A takeover shows the whole desktop.
- **Rate limit:** 1200 requests/min per token. The upstream 120/min is too tight once the live
  bridge polls frames.
- **No model provider keys:** the calling agent drives the browser over MCP.

## Live bridge

`bridge/` is a small Node service (no dependencies, node 20+) plus a stdio MCP
server. It runs as the `bridge` compose service: `node:22-alpine` pinned by
digest, host networking so it binds `127.0.0.1:6090` itself, uid 1000 so it can
read the 600 secrets, read-only root and source, all capabilities dropped.
Compose rather than a systemd user unit, so `browser-up`, `browser-status`,
`browser-logs` and `browser-down` cover all three pieces.

Phone routes, opened in the iOS app's in-app browser through the workspace proxy:

| Route | |
|---|---|
| `GET /live/<id>` | phone page: frame refreshed every 1.5 s, title and url, a pill (Watching / Needs you / Done), Take control, Done |
| `GET /live/<id>/frame.jpg` | latest frame, fetched server-side and cached 1 s; served with the upstream type, which is `image/png` |
| `GET /live/<id>/state` | `{"status":"watching"\|"takeover"\|"done","reason":string\|null,"url":string\|null,"title":string\|null}` |
| `POST /live/<id>/done` | ends a takeover (status `done`) and wakes the waiting agent |

- `<id>` is 128 random bits as 32 lowercase hex characters (`[0-9a-f]{32}`).
  One link per auto-browser session, reused. A link expires after 12 h without
  being viewed (`BRIDGE_LINK_IDLE_HOURS`). Unknown id → 404, expired → 410 (for 7
  days, then 404).
- When the session is deleted, state becomes `done` with reason `session_closed`.
- Private routes for the MCP server, `POST /api/{links,takeover,wait,release}`,
  need `Authorization: Bearer <bridge-token>`. The bridge refuses any Host header
  other than `localhost`/`127.0.0.1`/`[::1]` on its port (421).
- Neither the controller token, nor the VNC password, nor share tokens appear
  in `/state`, the logs, or `links.json`. Logs show the first 6 characters of a
  link id only.

**Frames.** The bridge mints a share (observer) token for the session and reads
`/share/<token>/observe`, then fetches the PNG it points to. This differs from
`POST /sessions/{id}/screenshot` on purpose: the share route prunes old frames,
whereas the screenshot route keeps every capture as an artifact, and a frame a
second would fill the disk. The path stays `frame.jpg`, as specified. Clients
must go by `Content-Type`, not the extension.

**Take control and the VNC password.** The button opens
`http://localhost:6080/vnc.html?autoconnect=true&resize=remote#password=<vnc-password>`.
This avoids a password prompt on the phone. The tradeoff is that the password is
in the page's HTML and in the noVNC URL. It sits in the fragment, so it is never
sent to a server or a proxy log, but it does live in the in-app browser's
history. That is acceptable because the password only guards a port that is
loopback-only and reachable from the phone only through the authenticated
workspace proxy. Anyone who can open the link could reach noVNC anyway. It is
also why `/live/<id>` is effectively a capability URL. To rotate the password,
move `secrets/vnc-password` to `~/trash/…`, then run `make browser-down browser-up`. That
regenerates it and restarts all three services; the bridge reads it at startup.

**DNS.** The LAN resolver (192.168.2.1) answers NXDOMAIN for `example.com`, so
the smoke test opens `news.ycombinator.com` (`SMOKE_URL=` to change).

MCP tools (`bridge/mcp.mjs`, stdio; it holds only the bridge token):

- `browser_live_link(session_id)` → `{link: "http://localhost:6090/live/<id>", ...}`.
  The description tells the agent to post the link in chat when it starts browsing.
- `browser_wait_for_human(session_id, reason, timeout_s=900)` asks auto-browser for a
  takeover, sets the link to `takeover` ("Needs you"), and sends
  `notifications/progress` with the link (when the client passes a progress
  token). It then blocks until the user taps Done → `{status:"done"}`, or until
  the timeout → `{status:"timeout"}`, after which the link goes back to `watching`.
  Set the client's tool timeout above `timeout_s`.

## Claude Code

Both are registered in user scope. Done once; the auto-browser token lands in `~/.claude.json`:

```
claude mcp add --transport http --scope user auto-browser http://127.0.0.1:8010/mcp \
  --header "Authorization: Bearer $(cat ~/.local/share/happy-browser/secrets/api-token)"
claude mcp add --scope user happy-browser-bridge -- node /home/prep/happy/selfhost/browser/bridge/mcp.mjs
```

## Happy Agent (prepared, needs your go-ahead)

The Happy Agent daemon runs in the `happy-agent` container with host networking,
so `127.0.0.1:8010` is the same port there. Its `mcp.toml`
(`~/.local/share/happy-agent/happy/config/mcp.toml`) hot-reloads, so adding an
entry takes effect at once. The entry below names an environment variable that
the running container does not have yet. It therefore waits for a container
recreate, which goes together with the pending seccomp decision.

Steps, after approval:

1. Back up and append to `mcp.toml`:

   ```
   TS=$(date +%Y%m%d_%H%M%S); mkdir -p ~/trash/${TS}_happy-agent-mcp-toml
   cp -p ~/.local/share/happy-agent/happy/config/mcp.toml ~/trash/${TS}_happy-agent-mcp-toml/
   ```

   ```toml
   [mcp_servers.auto_browser]
   url = "http://127.0.0.1:8010/mcp"
   bearer_token_env_var = "AUTO_BROWSER_TOKEN"
   enabled = true
   startup_timeout_sec = 20
   tool_timeout_sec = 120

   [mcp_servers.browser_bridge]
   command = "node"
   args = ["/home/prep/happy/selfhost/browser/bridge/mcp.mjs"]
   env = { HAPPY_BROWSER_HOME = "/home/prep/.local/share/happy-browser" }
   enabled = true
   startup_timeout_sec = 10
   # browser_wait_for_human blocks for up to timeout_s (default 900)
   tool_timeout_sec = 960
   ```

   `browser_bridge` needs no secret in the environment. It reads
   `secrets/bridge-token` itself; the container runs as uid 1000 and has
   `/home/prep` mounted. So it would work with the running container as soon as
   it is added. It is held back only so that both entries land together.

2. Recreate the container with the token in its environment. This is the current
   `docker inspect` config plus one `--env-file`; add whatever the seccomp decision
   requires:

   ```
   docker stop happy-agent && docker rename happy-agent happy-agent-old
   docker run -d --name happy-agent --network host --restart unless-stopped \
     --user 1000:1000 -w /home/prep/.local/share/happy-agent \
     -e HOME=/home/prep -e USER=prep \
     -e PATH=/home/prep/.local/bin:/home/prep/.bun/bin:/home/prep/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
     -e HAPPY_HOME_DIR=/home/prep/.local/share/happy-agent/.happy \
     -e HAPPY_SERVER_URL=https://happy.girthbass.duckdns.org \
     --env-file /home/prep/.local/share/happy-browser/secrets/happy-agent.env \
     -v /etc/ssl/certs:/etc/ssl/certs:ro -v /usr/bin/node:/usr/local/bin/node:ro \
     -v /usr/lib/node_modules:/usr/lib/node_modules:ro -v /home/prep:/home/prep \
     -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
     happy-agent-runtime:0.4.113 /home/prep/opt/happy-agent/happy-agent-linux-x64 run
   # keep the stopped happy-agent-old as the rollback until the new one has proved itself
   ```
