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

## Make targets (from `browser-stack/`; `selfhost/` includes the same fragments)

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

- **MCP:** `make mcp-register` gives each Mac harness an entry that runs the stack's
  gateway client on the Mac (`node ~/.local/share/browser-stack/client/mcp-gateway-client.mjs
  --url http://192.168.2.72:8904/browser/mcp`, and `/vault/mcp`). The client forwards to the
  LAN gateway on prep-ml with that Mac's key, and stamps each tool call with the chat it came
  from (`HAPPY_SESSION_ID`, `CLAUDE_CODE_SESSION_ID`, `HAPPY_FORKED_FROM_SESSION_ID` from the
  harness's environment). Nothing uses ssh at run time. `../README.md`, "The LAN gateway", has
  the details. `make gateway-mac-install HOST=<mac>` puts the client and the key there.
  Rollback: `MAC_TRANSPORT=ssh make mcp-register` writes the older `/bin/sh -c` wrapper,
  which runs the bridge on prep-ml over `ssh -o BatchMode=yes` with the ids on the remote
  command line (each blanked unless it matches `^[A-Za-z0-9_-]{1,128}$`).
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
  The Mac ssh tunnels (`com.happy.browser-forward`, `mac-forward/`) are retired; their files
  and make targets are in `/home/prep/happy-trash/20261107_001731_browser-forward/` on prep-ml.

### LAN listener

With `BRIDGE_LAN_BIND` and `BRIDGE_LAN_ALLOW` in `browser-stack/browser/.env.browser`, the bridge
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
  which the LAN gateway starts here) use loopback.
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
`make browser-status` shows 6090 on 127.0.0.1 only. Mac chats then lose the live view (the
old ssh tunnels are retired; see "Chats on the Macs" for where their files are).

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
- `secrets-bridge/` (uid 1992, 500; files 400): the bridge's copies of `api-token`,
  `vnc-password`, `bridge-token` and `filler-client-token`.
- `secrets-launcher/` (uid 1993, 500; files 400): the launcher's copies of `api-token`,
  `auth-state-key` and `share-token-secret`.
- `bridge/` (uid 1992, 700): the bridge's stores. `bridge/links.json` (600) holds live links
  (id, session, status, url, title, timestamps), no tokens.
- `data/` (uid 1993, 700): the controller's `/data`, holding artifacts, audit, sessions and
  auth, plus `pods/slot-N/` per pod. `browser-profile` and `downloads` (the shared stack's and
  each slot's) are 1993:1994, mode 775, and their contents belong to the node (1994).
- `run/` (1993:1996, 750): the launcher's socket, `launcher.sock` (660, group 1996).
- `run-docker/` (uid 1995, 750): the docker proxy's socket, `docker.sock` (660).

`secrets/` stays the operator's (`prep`, 600), so host tools (the stdio MCP server,
`make vault-tokens`, Happy Agent) keep reading it as before. `browser-init` copies what each
service needs into that service's own directory; nothing is group-readable. A copy is replaced
when the source changes, but a file removed from `secrets/` stays in the copies until moved
to trash by hand.

### Users and privileges

| uid / gid | Service |
|---|---|
| 1992 | `bridge` (also in group 1996, to reach the launcher's socket) |
| 1993 | `controller`, `launcher`, and each pod's controller; owns `data/` |
| 1994 | `browser-node` and each pod's node (Chromium) |
| 1995 | `docker-proxy` (also in the docker socket's group, `DOCKER_SOCKET_GID`) |
| 1996 | `LAUNCHER_SOCKET_GID`, the launcher socket's group |

Every service and every pod runs as its uid, with `cap_drop: ALL`, no capabilities added,
`no-new-privileges`, and a read-only root with a tmpfs `/tmp` (`HOME=/tmp`). Chromium keeps
its sandbox: its `/tmp` tmpfs allows exec, `shm_size` is 2g, and the node's seccomp profile
lets it make the user namespaces its renderers run in. Controllers get a `noexec` `/tmp`.
All uids are below 65536, so they map through a rootless daemon's subuid range. Override
them with `BRIDGE_UID`, `CONTROLLER_UID`, `BROWSER_NODE_UID`, `DOCKER_PROXY_UID` and
`LAUNCHER_SOCKET_GID` (none may be 0).

`browser-init` (run by `browser-up`) sets the owners and modes above and copies the secrets in
a one-shot container (`scripts/browser-perms.sh`) that runs as root with only `CHOWN`,
`DAC_OVERRIDE` and `FOWNER`, no network, and a read-only root. It changes only what differs,
so a second run reports 0 changes.

**Docker socket proxy.** The launcher never sees the docker socket. `docker-proxy/` (node, no
dependencies) listens on `run-docker/docker.sock` and forwards to
`${HAPPY_DOCKER_SOCKET:-/var/run/docker.sock}`, passing only what the launcher does:

- list, create, start, stop, inspect and remove the project's pod containers
  (`<project>-pod-<n>-{node,controller}`, matched by name and labels);
- exec `python3` in a pod's node as uid 1994 (no stdin), and start or inspect that exec;
- inspect or delete the two pinned images.

A create body must match the launcher's templates: host network, read-only root,
`CapDrop: ALL` and no `CapAdd`, `no-new-privileges`, the role's uid, a tmpfs only at `/tmp`,
and binds only under that slot's `data/pods/slot-N/` or read-only under the browser
directory, never the docker socket. Anything else gets a 403 and never reaches the engine.
Under rootless docker set `HAPPY_DOCKER_SOCKET` to the user's socket and
`DOCKER_SOCKET_GID=0`.

**Host network.** `browser-node`, `controller`, `bridge` and the pods stay on the host
network: the controllers and Chromium talk over the host's `127.0.0.1`, and the bridge
reaches auto-browser, the filler (6091) and each pod on their loopback ports. Publishing
ports from a bridge network would need each pod's ports mapped and the filler reachable
from inside, so it is not done. Every listener binds `127.0.0.1` only (the bridge also binds the LAN address when
`BRIDGE_LAN_BIND` is set). `docker-proxy` and `launcher` have no network at all; they talk
over unix sockets.

**Caveat:** `browser-pod-bench` connects to `run/launcher.sock` from the host, which the
operator can no longer open (it is 1993:1996, 660). Run it as a member of group 1996, or
from inside the bridge container.

Tunables, such as screen size, ports and `MAX_SESSIONS`, go in
`browser-stack/browser/.env.browser` (gitignored). Start from `.env.browser.example`.

## Settings worth knowing

- **Screen:** Xvfb is 1920x1200. This is a desktop screen, so sites serve their desktop
  layouts, at device scale factor 1 with no mobile user agent or device emulation. 16:10 is
  the shape of the iOS mini player, so the live frame fills it. Set `BROWSER_WIDTH`/
  `BROWSER_HEIGHT` in `.env.browser` to change it. The page is the screen less the desktop
  panel (28 px, `session.screen0.toolbar.height` in `kiosk/fluxbox/init.window`) and Chrome's
  87 px of tab strip and address bar (1920x1085): `browser.mk` works out
  `BROWSER_PANEL_HEIGHT` and `BROWSER_VIEWPORT_HEIGHT` from `BROWSER_KIOSK` and the fluxbox
  config, and hands them to the controller, the bridge frame and the launcher, so Playwright's
  viewport matches the maximized window exactly. The kiosk has no panel (1920x1200).
- **A normal browser window, maximized (`BROWSER_KIOSK=0`, the default):** `kiosk/` is
  mounted into browser-node. `happy-kiosk.mjs` runs in place of the image's `server.mjs` and
  holds every Chromium window (a `window.open` popup too) maximized below the desktop panel
  (1920x1172 at y 28) with its tab strip and address bar showing, re-checking every 2 s over CDP: a window someone makes
  fullscreen, minimizes or drags smaller comes back within a sweep. `kiosk/fluxbox/init.window`
  gives fluxbox a plain dark desktop (`kiosk/fluxbox/style`, solid #1e1e1e) with one panel,
  the fluxbox toolbar across the top: a flat grey bar (#2b2b2b, DejaVu Sans) with the window's
  button on the left and a clock on the right showing `%a %d %b %Y  %H:%M:%S` in the node's
  `TZ` (`EVIDENCE_TZ`, default `America/Toronto`, set on the shared node in compose and on
  every pod's node by the launcher). The panel is always shown and `maxOver: false` reserves
  its strip (`_NET_WORKAREA`), so a maximized Chromium never covers it. The window's button
  shows the window's own title, `<page title> - Google Chrome for Testing`: Chromium's
  `--window-name` does not reach the windows Playwright opens over CDP, and fluxbox 1.3.7 has
  no way to set a button's text without remote actions or key bindings, both of which stay off.
  No slit, menu, icons or key bindings, and `apps.window` maximizes every window with no frame.
  **The trade-off:** anyone in control of the live view (a takeover, or the noVNC page) can
  now type a URL into the address bar, open tabs and use the back button; the kiosk took that
  away. Agent actions are unchanged: they still go through the bridge and its approval rules,
  and the address bar is not a way round them for the agent. What a person can reach is
  limited by `kiosk/policy.json`: no guest mode, profiles, sign-in, sync, password manager,
  printing, translate or permission prompts; no extension installs; downloads go only to the
  profile's own directory with no file chooser; and `chrome://*`, `chrome-untrusted://*`,
  `devtools://*` and `file://*` are blocked (`ERR_BLOCKED_BY_ADMINISTRATOR`) apart from the new
  tab page. Playwright's contexts are off the record, so settings and extensions pages are
  unavailable anyway. Not covered: `DeveloperToolsAvailability` breaks Playwright (`newPage`
  fails), so DevTools is not blocked by policy and F12 by a person in control can open it.
  `view-source:` gets past the URLBlocklist (Chromium checks the inner URL, and
  `view-source:file:///etc/passwd` shows the file; a `view-source:*` entry has no effect), so
  the warden sends any page that commits a `view-source:` URL to `about:blank` at once.
  A known Chromium bug: with the URLBlocklist in force, `chrome://inspect` and then at once
  `chrome://downloads` (both blocked, back to back through Playwright) crash the browser
  process with SIGTRAP, a failed internal check, in about a third of tries; with no policy, or
  a second between them, it never happened in our runs. The browser-node exits with it. The
  shared stack's node comes back by itself (`restart: unless-stopped`); a pod's does not
  restart in place (`RestartPolicy: no`), but the bridge's health check stops it after two
  failed checks and the chat's next call gets a new pod on its last page, as for any crash.
- **The kiosk (`BROWSER_KIOSK=1`):** set it in `.env.browser` (or on the `make` line) to bring
  the kiosk back: every window held in browser fullscreen with no tab strip, address bar or
  frame, fluxbox on `kiosk/fluxbox/init`, and the page the full 1920x1200. Chromium's own
  `--kiosk` does not reach windows Playwright opens, so either way the lock is done over CDP.
  x11vnc runs with `-noremote -norc -nowf -nonap` in both modes. `make browser-bridge-smoke`
  (and the pod smoke) measures the window from inside the container
  (`scripts/kiosk-probe.mjs`) for the mode `BROWSER_KIOSK` names and checks no abstract X11
  socket is visible on the host. The takeover URL is
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
digest, host networking so it binds `127.0.0.1:6090` itself, uid 1992 reading its own
copies of the secrets in `secrets-bridge/`, read-only root and source, all capabilities
dropped.
Compose rather than a systemd user unit, so `browser-up`, `browser-status`,
`browser-logs` and `browser-down` cover all three pieces.

Phone routes, opened in the iOS app's in-app browser through the workspace proxy:

| Route | |
|---|---|
| `GET /live/<id>` | phone page: frame refreshed every 1.5 s, title and url, a pill (Watching / Needs you / Done), Take control, Done |
| `GET /live/<id>/frame.jpg` | latest frame, fetched server-side and cached 1 s; served with the upstream type, which is `image/png` |
| `GET /live/<id>/screen.png` | the whole pod screen (browser UI included) as `image/png`, captured in the pod, cached 1 s, one capture at a time per link. A link with no pod → 404; asleep pod → 503 |
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
  - `browser_screenshot` gets a `scope` argument, `"screen"` (the default) or `"page"`
    (forwarded to auto-browser as before, without `scope`: the viewport only). `"screen"` is
    the whole X display of the chat's own pod as the live view shows it, at native resolution,
    with the tab strip, address bar and toolbar, so the URL is in the picture (evidence). The
    result is a JSON text part with `scope`, `session_id`, `url`, `title`, `captured_at`,
    `width`, `height`, `screenshot_path`, `screenshot_url`, `pii_scrubbed` (and
    `screenshot_pii_scrub` when the scrub could not run), then the PNG as an image part.
    For a page on an `https://` URL a screen shot also has `address_bar_scheme`: `true` when
    OCR read `https://` in the address bar, `false` when it did not (the controller logs a
    warning; the shot is still filed), `"unknown"` when OCR is off or could not run. The
    address bar shows the full URL, scheme included, because `kiosk/policy.json` (the managed
    Chrome policy of the shared node and every pod) sets `ShowFullUrlsInAddressBar`.
    How a screen shot is taken (`POST /api/screen` -> `pods.screenShot`):
    1. the pod's controller brings the chat's session tab to the front
       (`/happy/sessions/<id>/screen/front`; skipped while the user holds control, and then
       refused unless the session's tab is already in front) and hands back a one-use token
       tied to that tab and URL;
    2. the launcher execs `scripts/screen-capture.py` in that pod's node as the
       node's uid (1994) (the pod id is checked, so a chat can only ever capture its own pod's screen);
    3. the controller (`/happy/sessions/<id>/screen/scrub`) checks the tab did not move or
       navigate, the window did not move, and the tab is still in front; OCRs the whole image
       and redacts PII as for page screenshots (strict mode withholds an image it cannot
       scrub), except in the browser's own UI strip; and only then files it in the session's
       artifact directory as `<time>-screen-<label>.png`.
    The address bar is never redacted: the URL is the point of the evidence. The strip (tab
    strip, address bar, toolbar) is the window's top `outerHeight - innerHeight` CSS pixels
    at `screenX`/`screenY`, `outerWidth` wide, times `devicePixelRatio`, read from the page at
    both steps (`chrome_strip` in the result; `source: "fallback"` if the geometry could not
    be read, then the top `CHROME_STRIP_FALLBACK_PX` of the screen). OCR words wholly inside
    it are left out of the redaction; the page and any other window are scrubbed.
  - `browser_screenshot` also gets `view`, for scope `"screen"`: `"desktop"` (the default,
    `SCREENSHOT_TIME_MODE` in compose) is the whole X screen, the desktop panel and its clock
    included; `"tab"` is the browser window alone, its rectangle (from the window's geometry,
    in screen pixels: `capture_rect`) read by `XGetImage` directly, never cropped afterwards,
    with no panel and no clock. Nothing is drawn on either: the clock in a desktop shot is the
    one the screen showed, so it is the node's own time in its `TZ`, and since it ticks once a
    second it can trail `captured_at` by up to about a second. The only change made to the
    captured pixels is the OCR PII redaction, and the result and the audit say whether it ran.
    `scripts/screen-capture.py` reads the time (`captured_at`, UTC, just before `XGetImage`),
    the screen size, the rectangle and the panel's height (`panel_px`, measured from
    `_NET_WORKAREA`, never assumed) and prints them on stderr; the launcher checks the PNG is
    that rectangle and adds `raw_sha256`, the PNG's sha256 as it came out of the capture; the
    controller refuses an image whose sha256 is not `raw_sha256` (`raw_hash_mismatch`) or that
    is not the rectangle the view needs (`bad_capture`), holds `captured_at` between its token
    time and now, and never redacts the panel. Screen results add `view`, `capture_rect`,
    `panel_px`, `evidence_bar_px` (the panel's height at the image's top: `panel_px` for
    desktop, 0 for tab), `captured_at`, `tz`, `raw_sha256` and `filed_sha256` (the image as
    filed: the same as `raw_sha256` unless it was redacted). The audit entry
    (`evidence_screenshot`) records the same fields; a redacted capture's raw image is not kept
    anywhere. A page shot records `filed_sha256`, `captured_at` (from its artifact name), `tz`,
    and `raw_sha256` only when it is unredacted. Cutover: the date/time bar the controller used
    to draw on screenshots (`happy_evidence_stamp.py`) is retired; shots taken before have it.
  - `browser_screenshot` also gets `redact` (boolean, default `true`). `false` is the explicit
    opt-in for full-fidelity evidence: the image is filed exactly as it was on screen, and the
    result says `pii_scrubbed: false, redaction: "off_by_request"` (a redacted one says
    `redaction: "on"`, or `"off_by_policy"` / `"unavailable"` when the deployment's scrubbing
    is off or OCR could not run). Every screen shot, and every unredacted page shot, is
    written to the controller's audit log as `evidence_screenshot` with `redacted`,
    `redaction` and the evidence fields above; an unredacted image that cannot be recorded there is not kept.
    `redact: false` works for both scopes with a pod of the chat's own: `"page"` then goes
    through the bridge (`POST /api/page-shot` -> the controller's
    `/happy/sessions/<id>/page-shot`) instead of upstream's tool; a redacted `"page"` is
    still upstream's own screenshot. On the shared browser `redact: false` is refused.
    `PII_SCRUB_SCREENSHOT_STRICT=true` makes scrubbing mandatory: the controller then refuses
    `redact: false` (403 `redaction_required`).
    Anything moving in between (another tab, navigation, the pod restarting) refuses the shot
    (one retry) rather than file a picture of something else. A pod still running an older
    controller patch answers 501 `screen_unsupported` until it restarts. With no pods (shared
    mode) `"screen"` is refused, as a shared display would show other chats' pages; a call
    without a scope then takes the page screenshot and says so.
    The live view's `/live/<id>/screen.png` is the raw, unscrubbed display, like noVNC.
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
claude mcp add --scope user happy-browser-bridge -- node /home/prep/happy/browser-stack/browser/bridge/mcp.mjs
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
args = ["/home/prep/happy/browser-stack/browser/bridge/mcp.mjs"]
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

On a Mac, Happy Agent's entry runs the gateway client with `--agent-db <the Mac's
agent.sqlite>`. The client does the lookup on the Mac (`identity/agentchat.py`, read-only,
`/usr/bin/python3 -I`) and stamps the chat it finds on the call, and the bridge on prep-ml
takes the chat from that stamp. A call it cannot place goes out without a chat and is
refused. `make mcp-register` brings an older Happy Agent entry it wrote up to date. With
`MAC_TRANSPORT=ssh` (rollback) the bridge runs on prep-ml instead and does the lookup as
`ssh <mac> python3 -I - <db> ...` (`BRIDGE_AGENT_SSH`).

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
