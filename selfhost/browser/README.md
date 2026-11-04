# Live browser for agents

An agent drives a real, headful Chromium. You watch it, or take control, from
the native iOS app. The app's in-app browser sends every request, including
ones to `localhost`, through the Happy Agent workspace proxy. So everything here
binds to `127.0.0.1` only. There is no public port, no Caddy route and no tunnel.

| Piece | Port (127.0.0.1) | What |
|---|---|---|
| auto-browser `browser-node` | 6080 | Xvfb + Chromium + noVNC (password required) |
| auto-browser `controller` | 8010 | REST API + MCP at `/mcp` (Streamable HTTP, bearer token) |

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

## Claude Code

Registered in user scope. Done once; the token lands in `~/.claude.json`:

```
claude mcp add --transport http --scope user auto-browser http://127.0.0.1:8010/mcp \
  --header "Authorization: Bearer $(cat ~/.local/share/happy-browser/secrets/api-token)"
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
   ```

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
