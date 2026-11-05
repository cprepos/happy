# Live browser for agents

An agent drives a real, headful Chromium. You watch it, or take control, from
the native iOS app. The app's in-app browser sends every request, including
ones to `localhost`, through the Happy Agent workspace proxy. So everything here
binds to `127.0.0.1` only. There is no public port, no Caddy route and no tunnel.

| Piece | Port (127.0.0.1) | What |
|---|---|---|
| auto-browser `browser-node` | 6080 | Xvfb + Chromium + noVNC (password required) |
| auto-browser `browser-node` | 9223 | Playwright server the controller drives Chromium through (`PLAYWRIGHT_PORT`) |
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
  - `happy-agent.env`: `AUTO_BROWSER_TOKEN=…`, for an MCP client that connects to `/mcp` directly. Happy Agent does not use it: it goes through the bridge's pass-through.
- `bridge/links.json` (600): live links (id, session, status, url, title, timestamps). No tokens.
- `data/`: the controller's `/data`, holding artifacts, audit, sessions and auth.
  - `data/browser-profile` and `data/downloads` belong to browser-node's uid 10001 and must stay mode 755.

Tunables, such as screen size, ports and `MAX_SESSIONS`, go in
`selfhost/browser/.env.browser` (gitignored). Start from `.env.browser.example`.

## Settings worth knowing

- **Screen:** Xvfb is 480x1040 and the page viewport is 480x950. This is phone-shaped, so sites
  serve narrow layouts and noVNC is legible on an iPhone. The takeover URL is
  `http://localhost:6080/vnc.html?autoconnect=true&resize=remote`.
- **Host networking:** all three services run with `network_mode: host`, so `localhost` in
  Chromium is this machine and agents can open loopback-only services here (for example
  `http://localhost:8903/v1/models`). There are no port publishes; each listener binds
  127.0.0.1 itself. The controller runs uvicorn with `--host 127.0.0.1 --port $API_PORT`. The
  Playwright server gets `PLAYWRIGHT_SERVER_HOST=127.0.0.1`, and the controller reaches it at
  the `ws://127.0.0.1:9223/...` endpoint it writes. The image's `/entrypoint.sh` starts
  websockify on a bare `6080`, which would bind every interface, so browser-node's entrypoint is
  `scripts/browser-node-entrypoint.sh`. That script patches noVNC to `127.0.0.1:$NOVNC_PORT` and
  starts Xvfb with `-nolisten tcp -nolisten local`, because the abstract X socket would otherwise
  sit in the host's network namespace. If the upstream lines stop matching, it refuses to start.
  x11vnc stays on its unix socket. `make browser-status` fails on any bind beyond 127.0.0.1
  across 6080, 8010, 6090 and 9223 (`BROWSER_PORTS`).
- **`ALLOWED_HOSTS=*`:** agents can go anywhere, including this machine's loopback services.
  Because of that the controller has to run with `APP_ENV=development`, since production mode
  refuses `*`.
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
- When the session has ended, state becomes `done` with reason `session_closed`.
  Ended means auto-browser reports it `closed` (deleted), `interrupted` (the
  controller restarted under it), `failed` or `ended`, or its shared observe
  answers 404; `/state` re-checks the session at most every 5 s, and a frame 404
  marks the link done at once. The page then says "This live browser has ended"
  and stops polling. A 404 for the frame *file* of a live session (pruned between
  observe and fetch) is a 502, not an end. After 4 failed frames in a row the page
  shows the error in the frame box and keeps retrying.
- The page fits 320-430 px phones: no fixed widths, safe-area insets, long
  titles ellipsized and URLs wrapped, and the frame box sized to the browser
  viewport (`BRIDGE_FRAME_WIDTH`/`BRIDGE_FRAME_HEIGHT`, from `BROWSER_WIDTH` and
  `BROWSER_VIEWPORT_HEIGHT`) with the image `object-fit: contain`.
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

MCP tools (`bridge/mcp.mjs`, stdio). Its own two tools use the bridge token; the
auto-browser tools it passes through use the controller token, which it reads
from `secrets/api-token` itself, so the client's environment and config hold no
secret.

- `browser_live_link(session_id)` → `{link: "http://localhost:6090/live/<id>", ...}`.
  The description tells the agent to call it right after creating a session and
  post the link in chat.
- `browser_wait_for_human(session_id, reason, timeout_s)` asks auto-browser for a
  takeover, sets the link to `takeover` ("Needs you"), and sends
  `notifications/progress` with the link (when the client passes a progress
  token). It then blocks until the user taps Done → `{status:"done"}`, or until
  the timeout → `{status:"timeout"}`, after which the link goes back to `watching`.
  `timeout_s` defaults to 900 and is capped at `BRIDGE_WAIT_MAX_S` (default 3600);
  keep the cap below the client's tool timeout.
- **Pass-through.** Every auto-browser MCP tool, listed from
  `http://127.0.0.1:8010/mcp` (Streamable HTTP; `AUTO_BROWSER_MCP_URL` to change)
  on each `tools/list` and appended after the two above. auto-browser names its
  tools with dots (`browser.observe`), which model APIs refuse in tool names
  (`^[a-zA-Z0-9_-]{1,64}$`), so every other character is mapped to `_`
  (`browser_observe`) in the name and in the descriptions, and mapped back when
  the call is forwarded. A name that would collide with one of the bridge's own
  tools is skipped. `browser_create_session`, `browser_observe` and
  `browser_request_human_takeover` get one sentence appended that points at
  `browser_live_link` / `browser_wait_for_human`.
  - A call is forwarded with its arguments and `_meta` (so a progress token
    reaches auto-browser, and its progress comes back), and auto-browser's result
    or JSON-RPC error is returned verbatim. Limit per call:
    `BRIDGE_PASSTHROUGH_TIMEOUT_S` (default 120).
  - The upstream MCP session (`Mcp-Session-Id`) is opened on first use; JSON and
    SSE responses are both read. If the controller restarted and no longer knows
    the session (404, or 400 about the session), a new one is opened and the
    call retried once.
  - auto-browser down: `tools/list` returns the bridge's own two tools, a call to
    an auto-browser tool returns a tool error ("not reachable ... Is the browser
    stack up?"), and the server retries in the background every 30 s and sends
    `notifications/tools/list_changed` once the tools are back. It never exits
    over it.
  - `BRIDGE_PASSTHROUGH=0` turns pass-through off.

## Claude Code

Both are registered in user scope. Done once; the auto-browser token lands in `~/.claude.json`:

```
claude mcp add --transport http --scope user auto-browser http://127.0.0.1:8010/mcp \
  --header "Authorization: Bearer $(cat ~/.local/share/happy-browser/secrets/api-token)"
claude mcp add --scope user happy-browser-bridge -- node /home/prep/happy/selfhost/browser/bridge/mcp.mjs
```

With `auto-browser` registered directly, the bridge's pass-through lists the
same tools a second time. To keep only its own two, register the bridge with
`-e BRIDGE_PASSTHROUGH=0`.

## Happy Agent

The Happy Agent daemon runs in the `happy-agent` container: host networking (so
`127.0.0.1:8010` and `:6090` are the same ports there), uid 1000, `/home/prep`
mounted read-write, and the host's node mounted read-only at
`/usr/local/bin/node` (node 20). It gets one stdio entry and no auto-browser
token: the bridge's MCP server reads both tokens from their 600 files, which uid
1000 can read in the container, and passes auto-browser's tools through. So the
container is not recreated and there is no `url = .../mcp` entry for
auto-browser.

`~/.local/share/happy-agent/happy/config/mcp.toml` (back it up to `~/trash/<ts>_mcp-toml/` first):

```toml
[mcp_servers.browser]
command = "/usr/local/bin/node"
args = ["/home/prep/happy/selfhost/browser/bridge/mcp.mjs"]
env = { HAPPY_BROWSER_HOME = "/home/prep/.local/share/happy-browser", BRIDGE_WAIT_MAX_S = "570" }
enabled = true
startup_timeout_sec = 20
# Happy Agent allows at most 600; browser_wait_for_human is capped at 570 s.
tool_timeout_sec = 600
```

Happy Agent caps `tool_timeout_sec` at 600, so a 15-minute wait in one call is
not possible there. `BRIDGE_WAIT_MAX_S = "570"` keeps `browser_wait_for_human`
inside the limit (the tool schema then reads "default 570, max 570"); on
`{status:"timeout"}` the agent can call it again. The tools show up as
`mcp__browser__browser_live_link`, `mcp__browser__browser_observe`, and so on.
They run only in Auto or Full access, and in Auto every call is reviewed.
