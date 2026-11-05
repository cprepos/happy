## Plan: one browser pod per chat, autoscaled, with the browser locked to a single window

All paths below are in the worktree `/home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser/` (it is identical to `/home/prep/happy/selfhost/browser/`). "AB" is the read-only auto-browser source at `/tmp/claude-1000/-home-prep-happy--dev-worktree-bright-bridge/cc66c2b4-b346-4610-bcd8-17e70cb0ea62/scratchpad/autobrowser/src`.

### A. Recommendation: the bridge runs each chat's containers itself, and each pod includes its own controller

**docker_ephemeral cannot work with our host-network setup.**
- It runs the per-session browser on a bridge network (AB `controller/app/session_isolation.py:653-696`, `network=network_name`). Chromium's `localhost` would then be the container, not this machine, so agents could no longer open loopback services here.
- It sets Playwright to `0.0.0.0:9223` and advertises it by container name (`:660-663`). The controller only reaches it by joining that network (`network.connect(controller_id)`, `:518`), and a `network_mode: host` container cannot join one.
- It publishes noVNC on a random host port (`:688-690`, `_extract_host_port` `:1021-1028`).
- It puts the Docker socket, which is root-equivalent, inside the large untrusted controller.
- It also bypasses our entrypoint patch.

**The controller cannot attach a session to a chosen Playwright endpoint.**
- In shared mode there is one global browser, taken from `BROWSER_WS_ENDPOINT_FILE`/`BROWSER_WS_ENDPOINT` (AB `controller/app/browser/services/runtime.py:40-88`, `:198-208`).
- `cdp_attach` swaps that global browser, and refuses while any session is live (`runtime.py:101-156`, `:129-134`).
- `create_session` has no endpoint parameter (AB `browser_manager.py:371-403`).
- The only per-session browser path is the Docker provisioner (`runtime.py:210-243`).

**So each chat gets a pod of two host-network containers:**
- a browser-node (noVNC `127.0.0.1:6100+n`, Playwright `127.0.0.1:9300+n`);
- its own controller (`127.0.0.1:8100+n`), with `MAX_SESSIONS=1`, its own `/data`, and `TAKEOVER_URL=http://localhost:6100+n/...`.

This needs no controller patches, keeps host-localhost browsing, keeps every listener on 127.0.0.1, and keeps our entrypoint guard. Each pod costs about 1.3–1.5 GiB (0.8 node + 0.4–0.6 controller).

**Display and ports.** The X socket `/tmp/.X11-unix/X99` is private to each container's `/tmp`, and our patch already passes `-nolisten local` (`scripts/browser-node-entrypoint.sh:212,223`). So every pod can keep `DISPLAY=:99` and only the ports differ.

Cross-pod reach is the same as today's risk:
- Pod B's noVNC is protected by its own random VNC password plus the Origin check.
- Pod B's controller is protected by the bearer token.
- Pod B's Playwright server is protected by its random wsPath (`runtime.py` comment at `:34-37`).

### B. Lifecycle and autoscaling

**Launcher (least privilege).** A new compose service, `launcher`, running `node:22-alpine` with no dependencies (new file `launcher/launcher.mjs`).
- It runs with `network_mode: none` and `cap_drop ALL`. It mounts `/var/run/docker.sock`, `${HAPPY_BROWSER_HOME}/data/pods` and `/chats` read-write, `secrets` read-only, and the repo's `browser/` read-only.
- It listens only on a unix socket at `${HAPPY_BROWSER_HOME}/run/launcher.sock` (0600, uid 1000). That directory is mounted into the bridge only, never into a pod.
- It speaks newline-delimited JSON with five allowlisted operations:
  - `ensure{slot, pod_id, vnc_password}`
  - `stop{slot}`
  - `list{}`
  - `adopt_auth{slot, chat_hash}`
  - `stash_auth{slot, chat_hash}`
- It validates every input: `slot` is an integer below `MAX_PODS`, ids match `/^[0-9a-f]{32}$/`, and the password matches `/^[A-Za-z0-9]{8}$/`.
- It builds the container specs from fixed templates and calls the Engine API over the socket. The image digests are the same as `compose.browser.yml:20-21`.
- The Engine API wants the seccomp JSON *content* in `SecurityOpt`, not a file path, so the launcher reads the file and passes it.
- Pods mirror today's compose: the node gets `compose.browser.yml:26-76` (caps, seccomp, `shm 2g`, `pids 2048`) plus `Memory 3g`, `NanoCpus 2`, `RestartPolicy no`, and labels `happy-browser.pod=1`, `slot`, `pod_id`. The controller gets `:78-143` with the per-pod port and URL, `MAX_SESSIONS=1`, `CONNECT_RETRY_DELAY_SECONDS=0.2` (AB `config.py:229`), and `Memory 1g`.
- Each slot's directory `data/pods/slot-N/` becomes the controller's `/data`. Its `browser-profile` and `downloads` subdirectories are the node's mounts.

**Start (cold).**
1. `ensure` wipes and recreates the slot directory, then creates and starts both containers at the same time. The controller retries until the endpoint file appears.
2. The readiness probe in the bridge `lib/pods.mjs` polls every 150 ms for 30 s. It needs both the controller's `GET /readyz` to return 200 (AB `routes/system.py:125-140`; it checks the browser connection with a bounded timeout) and `GET http://127.0.0.1:61NN/vnc.html` to return 200.
3. Then `adopt_auth` moves `chats/<hash>/auth/*` into `pods/slot-N/auth/`. The controller lists `AUTH_ROOT` with `iterdir` on every call (AB `browser/services/auth_profiles.py:492-497`), so there is no cache to invalidate.
4. Then `POST /sessions {auth_profile:'happy-chat'}`, only if the chat has saved auth.

**Warm pool.** Keep `BRIDGE_POD_WARM` spares (default 1, max 2), already started and ready, with no chat and no session. To assign one: `adopt_auth` + `create_session`, then refill the pool in the background while `running + warm < MAX_PODS`. A pod is never reused for a second chat: after it stops, it is wiped and recreated fresh.

**Startup estimates (need measuring):**

| Path | Estimate | Breakdown |
|---|---|---|
| Cold | about 4–8 s to the first observe | container create/start 0.5–1 s; Xvfb, Chromium and sandbox verify 2–4 s; controller Python import and Playwright driver 2–4 s, in parallel; `create_session` 0.3–0.8 s |
| Warm | about 0.4–1.2 s | auth move, `create_session`, optional auth restore |
| First pull | add the image pull | `make browser-pull` pre-pulls |

The measurement step is `scripts/pod-bench.mjs` (`make browser-pod-bench`). It runs 5 cold starts (warm pool set to 0) and 5 warm ones, and prints p50/p95 for each phase: `created`, `node_ready`, `ctl_ready`, `session_ready`, `first_observe`. The bridge logs these timings per start as well.

**Idle stop.** Each chat keeps two timestamps:
- `lastAgentAt`: every `/api/pod` call from `mcp.mjs`.
- `lastViewerAt`: every `/live/<id>/state` or `frame.jpg` request.

A pod is stopped when both are older than `BRIDGE_POD_IDLE_MIN` (default 10) and its link status is not `user` or `takeover`. The stop sequence is:
1. `POST /sessions/<sid>/auth-profiles {profile_name:'happy-chat'}` (AB `routes/auth_profiles.py:41`).
2. `stash_auth`.
3. `DELETE /sessions/<sid>`.
4. `stop` (stop and remove both containers, wipe the slot).
5. Set the chat to `asleep`.

The next agent call starts or assigns a pod and restores the login. Auth is also checkpointed after `/live/<id>/release` (when logins usually happen) and at most once every 60 s after mutating calls, so a crash loses at most about a minute of logins.

**Crash handling.** A 10 s health loop checks assigned pods using launcher `list` (container state) plus `/readyz`. After two failures it marks the chat `crashed`, stops the pod, and frees the slot. The next agent call starts a fresh pod with the last saved auth. The link id stays the same; only `sessionId` changes.

**Concurrency.** `BRIDGE_MAX_PODS` defaults to 8, hard cap 32 (port ranges 6100–6131, 8100–8131, 9300–9331). The launcher checks each port is free with `ss` or a connect check before creating. When all slots are in use, the bridge evicts the least-recently-active pod that nobody holds (normal idle stop). If every pod is active or held, the tool gets an error: "all N browsers are busy".

**Orphan cleanup on bridge restart.**
- The bridge saves `pods.json` (0600, in `/happy-browser/bridge`): slot, pod_id, vnc_password, chatKey, sessionId, state.
- At boot it calls launcher `list`. A container whose `pod_id` label matches a pod recorded as assigned and passes readiness is adopted. Anything else is removed, including old warm spares, then the pool is refilled.
- The launcher also removes labeled pods whose slot directory is missing.

### C. Window lock

**1. Chromium flags.** Add a wrapper mounted read-only at `/opt/browser-node/happy-kiosk.mjs`, rather than copying `server.mjs`. It sits there so `"playwright"` and `./server.mjs` resolve.

```js
import { chromium } from "playwright";
const launch = chromium.launchServer.bind(chromium);
chromium.launchServer = (o) => launch({ ...o, args: [...o.args, ...KIOSK] });
await import("./server.mjs");
```

`KIOSK` is: `--kiosk --window-position=0,0 --noerrdialogs --disable-session-crashed-bubble --hide-crash-restore-bubble --disable-pinch --overscroll-history-navigation=0 --deny-permission-prompts`.

Do **not** add any `--disable-features`. Chromium keeps only the last one, which would undo upstream's storage-partitioning list (AB `browser-node/server.mjs:26-63`).

Also set `DEFAULT_VIEWPORT_HEIGHT = BROWSER_HEIGHT` (1040) and `BRIDGE_FRAME_HEIGHT` to match. The roughly 90 px toolbar allowance at `compose.browser.yml:133-134,172` goes away.

**2. Managed policy.** Mount `kiosk/policy.json` read-only at `/etc/chromium/policies/managed/happy-kiosk.json`, and at the `chrome_for_testing` path as well (AB `browser-node/Dockerfile` copies to both). Contents: `BrowserGuestModeEnabled:false`, `BrowserAddPersonEnabled:false`, `PasswordManagerEnabled:false`, `TranslateEnabled:false`, `AutofillCreditCardEnabled:false`, `PrintingEnabled:false`, `DefaultNotificationsSetting:2`, `DefaultGeolocationSetting:2`, `PromptForDownloadLocation:false`.

Two more are empirical, see the checks list: `URLBlocklist ["chrome://*","devtools://*","view-source:*","file://*"]` with `URLAllowlist ["chrome://sandbox"]`, and `DeveloperToolsAvailability:2`.

**3. Window manager.** Keep fluxbox (it is in the image and handles fullscreen properly), locked down by read-only files in `kiosk/fluxbox/`:
- `init`: `session.screen0.toolbar.visible: false`, `session.screen0.workspaces: 1`, `session.screen0.defaultDeco: NONE`, `session.keyFile`, `session.appsFile`, `session.menuFile` pointing at the files below, and `session.screen0.allowRemoteActions: false`.
- `keys`: empty. That removes Alt-Tab, workspace keys and the root-menu mouse binding.
- `menu`: empty.
- `apps`: `[app] (name=.*) [Deco] {NONE} [Maximized] {yes} [Fullscreen] {yes} [end]`.

Run it as `fluxbox -rc /happy/fluxbox/init`. The alternative is no window manager at all (delete the line); that is empirical, since Chromium's fullscreen without a WM is unverified.

**4. Popups.** In kiosk mode, `target=_blank` and new tabs open as tabs of the one fullscreen window, with the tab strip hidden. A `window.open` popup (for example an OAuth sign-in) becomes a separate window, which fluxbox forces fullscreen and undecorated. The screen therefore always shows exactly one page, the top one; when it closes, the opener shows again.

The controller already tracks these through `context.on("page")` (AB `browser/services/diagnostics.py:205-212`) and `bring_to_front` (AB `tabs.py:143,189`). We cannot hook that event from browser-node, because Playwright connections do not share contexts, and the controller is not ours to patch.

Optional bridge fold (`BRIDGE_FOLD_TABS=1`): after mutating calls, if `/sessions/<sid>/tabs` has more than 1 tab and the newest has no `window.opener` need, close it and navigate the active tab to its URL. Keep at most 5 tabs. Do not use `--block-new-web-contents`, because it breaks OAuth popups.

**5. x11vnc.** Patch the x11vnc line (AB `browser-node/entrypoint.sh:89-90`) to add `-noremote -norc -nowf -nonap -clip ${WIDTH}x${HEIGHT}+0+0`. Keep `-forever -shared -unixsock`, the per-pod password file, and `-rfbport 0 -rfbportv6 0`. Change the noVNC URL from `resize=remote` (x11vnc ignores client resizes) to `resize=scale`.

**6. Entrypoint.** `browser-node-entrypoint.sh:211-229` already refuses to start unless each pattern matches exactly once. Extend it the same way with three more patterns:
- `^run_as_browser fluxbox >/tmp/fluxbox.log 2>&1 &$` gets `-rc /happy/fluxbox/init`;
- `-xkb >/tmp/x11vnc.log` gets the extra x11vnc options;
- `node /opt/browser-node/server.mjs` becomes `happy-kiosk.mjs`.

Phase 1 applies these to the existing shared stack too.

### D. Bridge changes

**Chat key, resolved in `mcp.mjs` per call:**
1. a chat or agent id in `params._meta` (to be confirmed in Phase 0);
2. otherwise env `CLAUDE_CODE_SESSION_ID`;
3. otherwise the fallback: one pod per auto-browser session. `create_session`, or `observe` without a `session_id`, allocates a new pod; calls with a `session_id` route through a sessionId → chat map; other calls go to the process's most recent pod. This is what applies to Happy Agent's single shared `mcp.mjs` if `_meta` carries nothing.

The key is `chatHash = sha256(source+':'+id).slice(0,32)`.

**Store.**
- Add `lib/pods.mjs`, the PodManager: slots, warm pool, the timers above, a launcher client, and one auto-browser client per pod (reusing `createAutoBrowserClient` from `lib/autobrowser.mjs:11` with `baseUrl` set to the pod's controller).
- Extend that client with `readyz`, `createSession`, `closeSession`, `saveAuthProfile`, `listTabs`.
- Add `chats.json` holding `{chatHash, source, linkId, slot, podId, sessionId, state: none|starting|running|asleep|crashed, lastAgentAt, lastViewerAt, hasAuth}`.
- `LinkStore` (`lib/store.mjs:121-142`) gets `forChat(chatHash)`. Records gain `chatKey` and the save field list at `:96-97` must include it. Links are per chat, so the URL already posted in chat keeps working across pod restarts.

**New private API endpoints:**
- `POST /api/pod {chat_key, wake}` → `{mcp_url, session_id, link_id, url}`. It ensures the pod, coalesces concurrent calls per chat, and counts as agent activity.
- `POST /api/pod/close` → save auth, close the session, stop the pod.
- `GET /api/tools`: the upstream tool list cached from any ready pod (and on disk), so `tools/list` never starts a pod.
- `/api/links`, `/api/takeover` and `/api/state` (`lib/app.mjs:229-258`) also accept `chat_key`. `session_id` still works for the legacy stack.

**Pass-through (`mcp.mjs:149-172`, `:282-296`):**
- Keep a `Map(mcp_url → createUpstreamMcp)`, because the Mcp-Session-Id is per controller.
- If a call fails with ECONNREFUSED *before* the request was sent, call `/api/pod` again and retry once.
- Inject or overwrite `args.session_id` with the chat's current session, which remaps stale ids after a restart.
- `browser_create_session` is idempotent: it returns the existing session, navigating if `start_url` is given.
- `browser_close_session` goes to `/api/pod/close`.
- `browser_fork_session` is refused ("one browser per chat").
- `browser_live_link`'s `session_id` becomes optional.
- `list_sessions` and auth tools need no filtering: a pod controller only sees its own session, and its `AUTH_ROOT` holds only this chat's profiles. That directory per chat is how auth profiles are namespaced; `happy-chat` is the name reserved for the bridge's own saves.

**`/take` and frames.**
- `/take` (`lib/app.mjs:292-296`) returns that pod's `novnc_url`: `http://localhost:${6100+n}/vnc.html?autoconnect=true&resize=off&view_clip=true#password=<pod pw>`.
- On an asleep pod, `/take` wakes it: it returns 202 with `pod:'starting'`, and iOS retries.
- `takeoverUrl` (`:79`) and `renderPage` (`:316`) become per record.
- `captureFrame` and `refreshMeta` (`:90-158`) use the pod's client.
- While asleep: `frame.jpg` returns 503 `{error:'asleep'}` and does not wake the pod; `/state` adds a field `pod: running|starting|asleep|crashed`. Do not add new status values, since iOS decodes the status (`packages/happy-ios/Sources/HappyCore/Browser/LiveBrowser.swift:203-212`).

**iOS.**
- In the card's `stop()` (`packages/happy-ios/Sources/HappyUI/Agents/LiveBrowserCardView.swift:146`) and `ChatViewController.viewDidDisappear` (`:436`), stop polling the feed (`packages/happy-ios/Sources/HappyCore/Browser/LiveBrowserFeed.swift:8,126`) and close the noVNC WebView. That stops viewer activity, so the idle timer can run.
- Leaving full screen goes to the mini player.
- Show "Asleep, wakes when the agent uses it" when `pod == asleep`.

### E. Tests and Make targets

**New `bridge/test/pods.test.mjs`** (node:test, with a fake launcher and fake per-pod clients that have injectable delay and failure). It checks:
- warm assignment does not wait on a cold start, and the pool refills;
- a cold start when the pool is empty;
- concurrent `ensure` calls for one chat start one pod;
- the cap and LRU eviction, and that held pods are never evicted;
- idle stop runs save → stash → close → stop, in that order;
- restore calls `createSession` with `auth_profile` only when the chat has auth;
- after a crash, the next call gets a new session id with the same link id;
- reconcile adopts known pods and removes unknown ones;
- viewer polls on an asleep pod do not wake it, and `/take` does.

**New `test/launcher.test.mjs`**, against a fake Engine API over a unix socket. It checks:
- specs use `NetworkMode=host`, all ports are 127.0.0.1 with no port bindings, and no pod mounts `docker.sock`;
- digests equal `compose.browser.yml:20-21`;
- the seccomp content equals the file;
- unknown operations and bad slot, id or password values are rejected;
- the entrypoint patch patterns each match exactly once against the AB entrypoint.

**Extend `passthrough.test.mjs` and `bridge.test.mjs`:**
- two chat keys reach two upstream URLs;
- `session_id` injection and remapping;
- idempotent `create_session`;
- `close` routes to `/api/pod/close`;
- `tools/list` comes from the cache without a pod;
- the retry once on ECONNREFUSED;
- per-pod `novnc_url` and password on `/take`;
- the `pod` field in `/state`.

**Real smoke, `scripts/pod-smoke.mjs`:**
- two chats get two pods with distinct ports, and `ss` shows only 127.0.0.1;
- kiosk checks through `browser_eval_js`: `outerHeight == innerHeight`, `screenX == 0`, `innerHeight == screen.height`; a `window.open` popup is fullscreen;
- the two noVNC passwords differ;
- with `BRIDGE_POD_IDLE_MIN=0.3`, the containers are gone after idle;
- logins survive: set localStorage on a local 127.0.0.1 test page the smoke starts, let it idle-stop, and check the value after the next call.

**Make targets** (`../browser.mk`):
- `browser-pods-status`: slots, chat, state, ports, idle age;
- `browser-pods-reap`: stop all labeled pods;
- `browser-pod-smoke`;
- `browser-pod-bench`;
- `browser-pull`;
- `browser-bridge-test` also runs the launcher tests;
- extend the `BROWSER_PORTS` check in `browser-status` (`browser.mk:41-44`) to the 61xx, 81xx and 93xx ranges.

### Phased plan

0. **Empirical checks.**
   - Behind `BRIDGE_LOG_META=1`, `mcp.mjs` logs to stderr the keys of `_meta` and of the client info, plus hashed `CLAUDE_CODE_SESSION_ID`/`HAPPY_*` env values, never raw values. Run it from Claude Code and from Happy Agent (`README.md:195-219`, `mcp.toml`).
   - Confirm the iOS proxy reaches `localhost:6100` (start a browser-node by hand on 6100) and that the noVNC Origin check passes under the alias host.
   - Time a manual cold start.
1. **Window lock on the current stack:** wrapper, policy, fluxbox files, entrypoint patterns, viewport, `resize=off&view_clip=true`, plus kiosk checks in `bridge-smoke`. This is independent and ships first.
2. **Launcher service and pod templates**, plus its tests and `browser-pods-*` targets.
3. **PodManager in the bridge**, plus `pods.test`.
4. **Routing:** `mcp.mjs` chat routing, per-chat links, per-pod `/take` and frames.
5. **iOS:** hide and stop streaming, asleep state.
6. **Measure and tune:** run the bench and set the warm-pool size. Keep the shared stack as a legacy fallback (for direct `/mcp` clients using `happy-agent.env`), or retire it.

### Risks
- The launcher holds the Docker socket, which is root-equivalent. Keep it tiny, unix-socket only, `network_mode: none`, allowlist only, and never give the socket to the controller or bridge.
- Host-port collisions in the 61xx, 81xx and 93xx ranges.
- Two containers per pod doubles container churn.
- If Happy Agent's `_meta` carries no chat id, the fallback gives one pod per auto-browser session, not per chat.
- After a restart the agent may still hold a stale session id; remapping mitigates this.
- Moving auth files may hit ownership problems if the controller writes `/data` as a different uid (`CONTROLLER_RUN_AS=auto`).

### Empirical checks still open
- Does Happy Agent's `_meta` carry a chat id?
- Does the proxy allow any localhost port?
- Does `--kiosk` fullscreen Playwright's new-context windows?
- Kiosk popup behaviour, and fluxbox `apps` matching Chromium popups.
- Does `DeveloperToolsAvailability:2` or `URLBlocklist chrome://*` break Playwright, `chrome://sandbox` verification, or new tabs?
- Real cold and warm timings.
- Controller memory per pod.
- Which uid owns files the controller writes in `/data/auth`.

### Critical Files for Implementation
- /home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser/bridge/mcp.mjs
- /home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser/bridge/lib/app.mjs
- /home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser/bridge/lib/store.mjs
- /home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser/scripts/browser-node-entrypoint.sh
- /home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser/compose.browser.yml (plus new `launcher/launcher.mjs`, `bridge/lib/pods.mjs`, `kiosk/`, and `/home/prep/happy/.dev/worktree/bright-bridge/selfhost/browser.mk`)

---

## Implementation notes

### Phase 0 findings (2026-11-04)

- **Claude Code** (`claude-code` client, run with `BRIDGE_LOG_META`): each Claude Code
  process spawns its own stdio `mcp.mjs`, so the process is per chat. `initialize`
  carries no `_meta`. Each `tools/call` `_meta` holds only `claudecode/toolUseId`
  (new per call) and `progressToken`. The CLI does **not** set
  `CLAUDE_CODE_SESSION_ID` for MCP children; it is present only when the session was
  launched by a parent that set it (the Happy CLI / agent SDK), and nested
  `claude -p` children inherit the parent's value.
- **Happy Agent**: one `mcp.mjs` per daemon (`happy-agent run`, started with the
  daemon), shared by every chat; its environment has `HAPPY_BROWSER_HOME`,
  `HAPPY_HOME_DIR`, `HAPPY_SERVER_URL` and no session id. Its bundled MCP client
  builds `_meta` from `claudecode/toolUseId`, `progressToken` and
  `claudecode/agentId`/`agentType` (the last two only for one built-in server).
  No chat id reaches the bridge. A runtime log needs the daemon to respawn its MCP
  child (`BRIDGE_LOG_META=/abs/path` in `mcp.toml` env), which was not done here.
- **Chat key decision**: `_meta` carries no chat id from either client, so the key
  is `CLAUDE_CODE_SESSION_ID` when the process has it, else the fallback: one pod
  per auto-browser session (create_session / observe without a session allocate,
  calls with a session id route by a sessionId -> chat map, others go to the
  process's most recent pod).
- **Phone proxy**: `BrowserLoopback` (iOS) aliases any loopback port and rewrites
  `Host`/`Origin`/`Referer` back to `localhost:<port>`, so noVNC on `localhost:61NN`
  sees a loopback same-origin request, as on 6080. Not checked from a phone.

### Phase 1 findings (window lock)

- `--kiosk` (and `--start-fullscreen`) do **not** reach windows Playwright opens: its
  contexts start with `--no-startup-window` and every window is made over CDP. Measured:
  inner 472x949 in a 480x1040 screen with the flag. `kiosk/happy-kiosk.mjs` therefore
  runs a warden (a browser-level CDP session on its own server) that sets every page
  target's window to `windowState: fullscreen` on `Target.targetCreated` and re-checks
  every 2 s. After it: page and `window.open` popup are both 480x1040 at 0,0; a window
  forced back to `normal` is fullscreen again within one sweep.
- The managed policy loads (chrome://policy lists every key). `DeveloperToolsAvailability`
  and `URLBlocklist chrome://*` were left out: not needed for the lock, and untested
  against the sandbox check.
- `ss -xlH` on the host shows only the path socket `/tmp/.X11-unix/X99` (container `/tmp`),
  never `@/tmp/.X11-unix/...`; the smoke asserts it.

### Phase 2 findings (launcher)

- Cold pod start, manual (warm image cache): launcher create+start 0.43 s, noVNC up
  1.0 s, controller `/readyz` 3.0 s, `POST /sessions` 0.43 s; about 3.5 s in all.
- Idle pod memory: node 278 MiB, controller 164 MiB.
- The controller (CONTROLLER_RUN_AS=auto) writes `/data/auth` as the owner of `/data`
  (uid 1000, which the launcher chowns the slot to); profiles are
  `auth/profiles/<name>/{profile.json,state.json.enc}`.
- `adopt_auth` copies rather than moves (the chat keeps its saved login until a newer
  one replaces it); `stash_auth` keeps the previous one as `profiles.prev`, and
  `keep: true` copies without removing (the checkpoint after a release).
- Unix socket paths are limited to 108 bytes; a test HAPPY_BROWSER_HOME under a long
  scratch path needs a relative connect.

### Phase 3 findings (pod manager)

- `lib/pods.mjs` drives the launcher; one link per chat (`store.forChat`) survives pod restarts.
- Stop sequence: save the `happy-chat` auth profile, `stash_auth` to `chats/<key>/auth`,
  close the session, launcher `stop`. 330-450 ms. Wake restores the profile with `adopt_auth`;
  a session that fails with the profile is retried without it.
- Bug found by the smoke: a `refill()` with nothing to do finished synchronously and left a
  settled promise in `refilling`, which blocked every later refill (no spare after the first
  one was taken). Fixed by yielding before the loop; regression test in `pods.test.mjs`.

### Phase 4 findings (routing)

- Chat identity in the MCP process: `HAPPY_SESSION_ID` (set by the Happy CLI for the agent's
  MCP servers), then `CLAUDE_CODE_SESSION_ID`. Key: `sha256("<source>:<id>")[:32]`.
  The Happy Agent runs one shared MCP process per daemon with no per-chat env; `_meta` on its
  calls carries only `claudecode/toolUseId` and `progressToken`. It falls back to one pod per
  browser session (no chat key the app could compute).
- Happy Agent, per call (`BRIDGE_AGENT_DB`, 2026-11-05): Happy Agent is an upstream binary, so it
  can neither spawn a bridge per chat nor add a chat id to `_meta`. But the `claudecode/toolUseId`
  it sends is its own tool call id, and it journals `tool.started` (agent id, `toolCall.id`) in
  `agent.sqlite` before running the tool. `lib/agentchat.mjs` looks the id up read-only and takes
  the agent's Happy session (`happy_agent_happy_sessions.remote_session_id`), so the key matches a
  Happy CLI chat's. Unmatched calls are refused; tool arguments never pick the chat.
- App discovery: `GET /live/chat/<key>` (public, like `/live/<id>`), with
  `key = sha256("happy:" + happySessionId)[:32]`. Answers `{id, url, live, pod, status, ...}`,
  404 `no_link` when the chat never had a browser. `live` is false once the pod sleeps or the
  link is done.
- `execute_action` takes `{session_id, action: {action, url, reason, ...}}`; `eval_js` needs
  operator approval (approval_required), so the smoke sets its cookie with a navigation.

### Phase 6 measurements (hbk test project, 2026-11-05, `make browser-pod-bench`, 5 runs each)

| phase | cold p50/p95 | warm p50/p95 |
|---|---|---|
| ensure (what the agent waits) | 3478/3522 ms | 473/476 ms |
| containers created | 356/369 ms | - |
| node ready (noVNC) | 970/1009 ms | - |
| controller ready | 3010/3021 ms | - |
| session created | 460/504 ms | 472/474 ms |
| stop (save, stash, close, stop) | 347/451 ms | 415/448 ms |

- Waking an idle-stopped chat from a spare: 419 ms, signed in (cookie kept), same link.
- One warm spare (default `BRIDGE_POD_WARM=1`) covers a single new chat at a time; a second
  concurrent new chat takes the spare that is still starting (about 3.4 s). Idle memory per pod
  is about 440 MiB, so a second spare is not worth it on this host.
- `make browser-pod-smoke` passes: two chats, two pods, own ports and noVNC passwords, every
  listener on 127.0.0.1, no abstract X11 socket, kiosk lock in both, idle stop, login survives.
