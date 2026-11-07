# Live browser for agents

An agent drives a real, headful Chromium. You watch it, or take control, from
the native iOS app. The app's in-app browser sends every request, including
ones to `localhost`, through the Happy Agent workspace proxy. So everything here
binds to `127.0.0.1` only. There is no public port and no Caddy route. The one opt-in
exception is the bridge's LAN listener (below): port 6090 on one LAN address, for a fixed
list of client addresses.

| Piece | Port (127.0.0.1) | What |
|---|---|---|
| auto-browser `browser-node` | 6080 | Xvfb + Chromium + noVNC (password required) |
| auto-browser `browser-node` | 9223 | Playwright server the controller drives Chromium through (`PLAYWRIGHT_PORT`) |
| auto-browser `controller` | 8010 | REST API + MCP at `/mcp` (Streamable HTTP, bearer token) |
| live `bridge` (`bridge/`) | 6090 | phone page `/live/<id>`, frames, state, takeover hand-back; plus a stdio MCP server. Optionally also on `192.168.2.72:6090` for the Macs (LAN listener) |

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
make browser-bridge-smoke   # end to end on the running stack; makes and deletes one session (and,
                            # with pods, one throwaway chat's pod)
make browser-pods-status    # each chat's pod: slot, containers, the bridge's view (chat, held, idle)
make browser-pods-reap      # remove pods no chat is using; asks first (see below)
make browser-forward-install HOST=prep-air   # Mac tunnel for the live view (also -status, -uninstall)
make browser-bridge-restart BRIDGE_ENV=1     # recreate only the bridge, so a changed .env.browser applies
```

`make browser-pods-reap` keeps every pod the bridge says is in use: one with a chat's
active session, one whose link the user holds (take control or a takeover), one starting,
or one used in the last `REAP_RECENT_MIN` minutes (10). The rest (warm spares, slots the
bridge does not know) are listed and removed only after a yes on a terminal. Without a
terminal, or with `DRY_RUN=1`, it only lists them. When the bridge does not answer nothing
is removed. `FORCE=1` removes every pod container of the project without asking, as the
target used to. Saved logins (`data/chats`) are never touched.

## Chats on the Macs (prep-air, prep-pro)

The browser stack runs only here. A Mac chat reaches it two ways:

- **MCP:** `make mcp-register` gives each Mac harness a `/bin/sh -c` entry that runs
  the bridge (and the vault) on prep-ml over `ssh -o BatchMode=yes`, passing the
  chat's `HAPPY_SESSION_ID`, `CLAUDE_CODE_SESSION_ID` and
  `HAPPY_FORKED_FROM_SESSION_ID` on the remote command line (ssh forwards no env).
  Each value must match `^[A-Za-z0-9_-]{1,128}$` or it is sent blank.
- **Live view and takeover:** over the LAN, through the bridge's LAN listener below
  (`http://192.168.2.72:6090`), sent through the chat machine's workspace proxy. A live link
  names its bridge origin, `http://localhost:6090` for a prep-ml chat or
  `http://192.168.2.72:6090` for a Mac chat (`LiveBrowserLink.origins` in
  `packages/happy-ios`, the one list of them); the app recognizes exactly those two. The
  links the MCP server hands a Mac chat use the LAN origin (`BRIDGE_PUBLIC_BASE`, which
  `mcp-register` sets in the Mac wrappers). The app's by-chat lookup tries the LAN origin,
  then localhost, and keeps the one that answers: from prep-ml the LAN listener refuses the
  connection (prep-ml's own address is not allowed in), from a Mac nothing listens on
  localhost:6090.
  The Mac ssh tunnels (`com.happy.browser-forward`, `mac-forward/`) were removed on
  2026-11-06 and nothing installs them. Their targets stay only for a rollback:
  `make browser-forward-install HOST=prep-pro` puts one back (127.0.0.1:6090 and :6080 on
  the Mac), `make browser-forward-uninstall HOST=...` moves its plist to `~/happy-trash/`.
  App builds from before the per-link origin (OTA-only devices not yet updated) need them.

### LAN listener

With `BRIDGE_LAN_BIND` and `BRIDGE_LAN_ALLOW` in `selfhost/browser/.env.browser`, the bridge
listens a second time, on `<BRIDGE_LAN_BIND>:6090`, beside `127.0.0.1:6090`:

```
BRIDGE_LAN_BIND=192.168.2.72
BRIDGE_LAN_ALLOW=192.168.2.55,192.168.2.56
```

then `make browser-bridge-restart BRIDGE_ENV=1` (a plain restart keeps the old environment).

- Only port 6090 is exposed. noVNC's files and its websocket go through the bridge
  (`/live/<id>/vnc/...`), so take control needs nothing else. 6080, 8010, 9223, the pods'
  ports and the filler's 6091 stay on 127.0.0.1.
- **Client allowlist:** a connection from any address not in `BRIDGE_LAN_ALLOW` is destroyed
  on connect, and every request and upgrade is checked again (403 `forbidden`, logged as
  `lan-refused`) before any routing. IPv4 only, exact addresses, no ranges.
  `BRIDGE_LAN_BIND` must be one IPv4 address (not `0.0.0.0` or loopback) and the allowlist
  must not be empty; otherwise the bridge refuses to start.
- **Host:** the LAN listener answers only to `Host: 192.168.2.72:6090` (421 otherwise), and
  the loopback listener does not answer to that Host.
- **No private routes:** `/api/*` is 404 on the LAN listener; the MCP servers (also the Macs',
  which run here over ssh) use loopback.
- **URLs:** absolute URLs the LAN listener returns (`/live/chat/<key>`'s `url`, `/take`'s
  `novnc_url`, the page's Take control link) use `http://192.168.2.72:6090`
  (`BRIDGE_LAN_PUBLIC_BASE` to change). Loopback responses keep `http://localhost:6090`; the
  MCP server moves the live-page URLs in them to `BRIDGE_PUBLIC_BASE` when that is set (the
  Mac wrappers).
- Live link ids are still the capability: 128 random bits per link.
- `make browser-status` then accepts `192.168.2.72:6090` as the one bind beyond 127.0.0.1
  and fails on any other.

**Firewall, as root (no target applies it).** prep-ml runs ufw, enabled with
`DEFAULT_INPUT_POLICY="DROP"`, so until it admits the Macs their connections to
`192.168.2.72:6090` time out (seen 2026-11-06): the ufw rules below are required there, not
only defence in depth. On a host without a firewall, the iptables form is the optional
second layer; it is inserted in this order so the accepts sit above the drop:

```
sudo iptables -I INPUT -p tcp -d 192.168.2.72 --dport 6090 -j DROP
sudo iptables -I INPUT -p tcp -d 192.168.2.72 --dport 6090 -s 192.168.2.56 -j ACCEPT
sudo iptables -I INPUT -p tcp -d 192.168.2.72 --dport 6090 -s 192.168.2.55 -j ACCEPT
```

or, where ufw is enabled with its default deny incoming (prep-ml):

```
sudo ufw allow proto tcp from 192.168.2.55 to 192.168.2.72 port 6090
sudo ufw allow proto tcp from 192.168.2.56 to 192.168.2.72 port 6090
```

The bridge runs with host networking and publishes no port, so these INPUT rules apply to it
directly (Docker's own chains are not involved). Undo with `sudo ufw delete allow proto tcp from 192.168.2.55 to 192.168.2.72 port 6090`
(and `.56`).

Rollback: remove (or comment out) the two lines from `.env.browser` (back it up to
`~/trash/<ts>_env-browser/` first), run `make browser-bridge-restart BRIDGE_ENV=1`, and check
`make browser-status` shows 6090 on 127.0.0.1 only. Mac chats then lose live view until the
tunnels are back: `make browser-forward-install HOST=prep-pro` (and `HOST=prep-air`), and
`make mcp-register` from a checkout whose `REMOTE_LINK_BASE` (`scripts/mcp-register.py`) is
`http://localhost:6090`.

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

- **Screen:** Xvfb is 1920x1200 and so is the page: the window is locked (below), so the page
  fills the whole screen. This is a desktop screen, so sites serve their desktop layouts, at
  device scale factor 1 with no mobile user agent or device emulation. 16:10 is the shape of
  the iOS mini player, so the live frame fills it. Set `BROWSER_WIDTH`/`BROWSER_HEIGHT` in
  `.env.browser` to change it.
- **One window, nothing else on screen:** `kiosk/` is mounted into browser-node.
  `happy-kiosk.mjs` runs in place of the image's `server.mjs` and holds every Chromium window
  in browser fullscreen (no tab strip, address bar or frame; a `window.open` popup too),
  re-checking every 2 s. Chromium's own `--kiosk` does not reach windows Playwright opens, so
  the lock is done over CDP. `kiosk/fluxbox` gives fluxbox no toolbar, menu or key bindings,
  `kiosk/policy.json` turns off guest mode, profiles, the password manager, printing and
  permission prompts, and x11vnc runs with `-noremote -norc -nowf -nonap`. `make
  browser-bridge-smoke` measures the window from inside the container
  (`scripts/kiosk-probe.mjs`) and checks no abstract X11 socket is visible on the host. The takeover URL is
  `http://localhost:6080/vnc.html?autoconnect=true&resize=scale`: noVNC scales the whole
  desktop down to fit the phone (pinch-zoom for detail), so there is nothing to pan.
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
| `GET /live/<id>/vnc/<file>` | noVNC's own files (`vnc.html`, `app/…`, `core/…`), from the link's pod's websockify (`127.0.0.1:6100+slot`), or the shared `127.0.0.1:6080` for a link with no pod. Asleep pod → 503 |
| `GET /live/<id>/vnc/websockify` (Upgrade: websocket) | the VNC socket, piped to that same noVNC's `/websockify`; only while the link is `user` or `takeover` (else 403) |

- **noVNC through the bridge.** Take control needs no port but 6090. The upstream port
  always comes from the bridge's own record of the link (its pod, or the shared noVNC),
  never from the request, so this is not an open proxy. `<file>` is matched on the raw
  path: each segment is `[A-Za-z0-9_-][A-Za-z0-9._-]*`, so `..`, encoded characters, a
  leading `/` and empty segments are refused (400) before anything is forwarded. Cookies,
  `Authorization`, `Set-Cookie`, `WWW-Authenticate` and `Location` are dropped both ways;
  only a short list of content headers crosses. The socket is closed when the link is
  released, ended or expires, or when its pod stops or is replaced (checked every second).
  Every other upgrade request is refused.
- **Restarts.** On SIGTERM/SIGINT the bridge releases every `user`/`takeover` link like a
  Release control (reason `bridge_restarting`): noVNC sockets close, a waiting
  `browser_wait_for_human` returns `{status: "released"}` so the agent can ask again, and
  `links.json` is saved before it exits. Pods and links stay. `make browser-bridge-restart`
  lists the links it will release (id prefix and title), restarts only the bridge
  container, and waits for `/healthz`.

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
  viewport's aspect ratio (`BRIDGE_FRAME_WIDTH`/`BRIDGE_FRAME_HEIGHT`, from
  `BROWSER_WIDTH` and `BROWSER_HEIGHT`) at 100% of the page width, with the image
  `object-fit: contain`, so a 1920-wide frame scales down to the phone.
- Private routes for the MCP server, `POST /api/{links,takeover,wait,release}`,
  need `Authorization: Bearer <bridge-token>` and exist on loopback only. The loopback
  listener refuses any Host header other than `localhost`/`127.0.0.1`/`[::1]` on its port
  (421); the LAN listener, any but `<BRIDGE_LAN_BIND>:<port>`.
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
`http://localhost:6090/live/<id>/vnc/vnc.html?autoconnect=true&resize=scale&path=websockify#password=<vnc-password>`
(the pod's own password for a pod link). `/take` returns the same absolute URL as
`novnc_url`; the phone page reopens it at its own origin and path prefix.
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

- `browser_live_link(session_id)` → `{link: "http://localhost:6090/live/<id>", ...}`
  (`http://192.168.2.72:6090/...` for a Mac chat, `BRIDGE_PUBLIC_BASE`).
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
env = { HAPPY_BROWSER_HOME = "/home/prep/.local/share/happy-browser", BRIDGE_WAIT_MAX_S = "570", BRIDGE_AGENT_DB = "/home/prep/.local/share/happy-agent/.happy/agent/agent.sqlite" }
enabled = true
startup_timeout_sec = 20
# Happy Agent allows at most 600; browser_wait_for_human is capped at 570 s.
tool_timeout_sec = 600
```

Happy Agent runs this one process for all of its chats, with no chat id in its
environment. `BRIDGE_AGENT_DB` gives each call its chat anyway: the daemon
journals every tool call it starts (`tool.started`: the agent, the call id, the
tool and its arguments) before running it, so `mcp.mjs` finds this call's record
in the daemon's database (read-only, through `browser-stack/identity/agentchat.py` and the
container's `python3`; Node 20 has no SQLite) and takes the agent's Happy
session. A client that names its call in `_meta["claudecode/toolUseId"]` is
looked up by that id. Happy Agent as deployed sends no `_meta` at all (seen with
`BRIDGE_LOG_META`, 2026-11-05), so its call is the one in-flight `tool.started`
record of the same tool with exactly the same arguments that has not completed
and was not matched before. The arguments only find the daemon's own record; the
chat is the agent that record names, never a value in them.

The chat key is then `sha256("happy:" + Happy session id)[:32]`, the same as a
Happy CLI chat's, and with pods on each chat gets its own pod and is found with
`GET /live/chat/<key>`. An agent with no Happy session gets
`sha256("agent:" + agent id)[:32]`. A call id that can't be found, and identical
calls in flight from two chats, are refused ("try it again"), never routed by
the session they name. A call with no id that isn't in the journal is routed by
its browser session, as before. Without `BRIDGE_AGENT_DB` every browser session
gets a pod of its own, as before.

On a Mac, Happy Agent's bridge runs here over ssh (`make mcp-register`), and its
entry passes `BRIDGE_AGENT_DB=<the Mac's agent.sqlite>`,
`BRIDGE_AGENT_SSH=<the Mac>` and `BRIDGE_AGENT_PYTHON=/usr/bin/python3`: the
lookup runs on that Mac as `ssh <mac> python3 -I - <db> ...` with the script and
the request on stdin (about 0.2 s a call). `make mcp-register` brings an older
Happy Agent entry it wrote up to date.

The vault secret tools (`browser_list_secrets`, `browser_fill_secret`,
`browser_login`) in such a process name the chat `none` to the secret filler,
which serves it only when its policy sets `default_client`
(`filler/README.md`); otherwise they answer "no chat id".

Happy Agent caps `tool_timeout_sec` at 600, so a 15-minute wait in one call is
not possible there. `BRIDGE_WAIT_MAX_S = "570"` keeps `browser_wait_for_human`
inside the limit (the tool schema then reads "default 570, max 570"); on
`{status:"timeout"}` the agent can call it again. The tools show up as
`mcp__browser__browser_live_link`, `mcp__browser__browser_observe`, and so on.
They run only in Auto or Full access, and in Auto every call is reviewed.
