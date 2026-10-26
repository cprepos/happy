# Cutover: voice audio through happy-server only

Moves LiveKit off the host network onto happy-server's docker network and removes every public
path to it. After this, apps reach voice only through `wss://happy.girthbass.duckdns.org/v1/voice/stream`.

Prepared on branch `voice-bridge-infra`; nothing here has been applied. Run the steps in order.
Every step that changes something has a backup step before it and a rollback entry below.

## What changes

| Piece | Before | After |
|---|---|---|
| LiveKit container | `network_mode: host`, signaling 127.0.0.1:7880, ICE/TCP `*:7881`, UDP mux 7882 on LAN + VPN IPs, STUN for the public IP | on `happy-selfhost_default` (alias `livekit`, IP assigned by Docker), signaling published on `127.0.0.1:7880` only, 7881/7882 only on the container IP, no STUN |
| `livekit.yaml` | `use_external_ip: true`, `advertise_internal_ip: true`, `ips.includes` LAN + VPN, `bind_addresses: 127.0.0.1` | `use_external_ip: false`, `ips.includes: 172.24.0.0/16`, binds all addresses inside the container |
| happy-server | `LIVEKIT_PUBLIC_URL` (handed to apps) | `LIVEKIT_URL=ws://livekit:7880` (used by the server's own bridge) |
| Caddy | `livekit.girthbass.duckdns.org` site and `girthbass.duckdns.org/livekit*` block, both proxying to 127.0.0.1:7880 | both removed |
| ufw | four rules from 2026-10-25 for 7881/tcp and 7882/udp (LAN and VPN) | deleted (needs sudo, done by the user) |
| voice agent | host network, `ws://127.0.0.1:7880` | unchanged. Media now goes from the host to the container IP |

**Why there is no fixed IP:** Docker refuses `ipv4_address` on a network without a user-configured
subnet ("user specified IP address is supported only when connecting to networks with user
configured subnets"). I checked this on a scratch network. `happy-selfhost_default` was created by
compose without an `ipam` block, so it is that kind of network. A fixed IP isn't needed:

- LiveKit takes its node IP from its interface, and `rtc.ips.includes: 172.24.0.0/16` keeps that
  address as its only ICE candidate.
- happy-server uses the DNS alias `livekit`.
- The agent gets the address from signaling.

A fixed IP would mean adding `ipam` to `docker-compose.yml`, which recreates the network and takes
postgres and happy-server down. That isn't worth it.

**Host to container media (verified with scratch containers):**

- **Test:** a throwaway `livekit-server:v1.13.10` ran on a scratch bridge network with this
  config, no RTC ports published, and signaling published on 127.0.0.1.
- **Result:** two `livekit.rtc` participants on the host network joined through 127.0.0.1 and
  exchanged audio. ICE chose `172.25.0.2:7882 (host) <-> 172.25.0.1 (prflx)` over UDP.
- **Why ufw doesn't block it:** the agent's packets start on the host, so they pass ufw's OUTPUT
  chain, not INPUT or FORWARD. The container's replies come back as conntrack ESTABLISHED.

`check-no-public-livekit.sh` tests the real stack the same way after cutover. It checks TCP to
`<container-ip>:7881` and `make voice-agent-e2e` exercises UDP.

## Preconditions

1. The server part (`/v1/voice/stream` bridge, `LIVEKIT_URL`) and the web client are merged.
   Today's web client talks to LiveKit directly and **stops working at step 2** (no LAN media, then no
   public signaling at step 5). Deploy the new
   webapp in the same window.
2. Baseline latency, still on the old setup (for the comparison in "Latency" below):
   ```sh
   make -C /home/prep/happy/selfhost voice-agent-e2e 2>&1 | tee /tmp/voice-baseline-e2e.txt
   ```

## Steps

```sh
TS=$(date +%Y%m%d_%H%M%S)
SH=/home/prep/happy/selfhost
VOICE="docker compose -p happy-voice -f $SH/compose.voice.yml --env-file $SH/.env.voice"
```

### 1. Backups (nothing changes yet)

```sh
B=/home/prep/happy/trash/${TS}_voice_cutover
mkdir -p "$B"
cp -a $SH/.env $SH/.env.voice "$B/"                          # secrets: stays local, never commit
cp -a $SH/livekit.yaml       "$B/livekit.yaml.before"        # still the old files: merge comes after this step
cp -a $SH/compose.voice.yml  "$B/compose.voice.yml.before"
cp -a $SH/docker-compose.yml "$B/docker-compose.yml.before"
git -C /home/prep/happy rev-parse HEAD > "$B/selfhost-head-before.txt"
docker inspect happy-voice-livekit happy-selfhost-happy-server-1 > "$B/docker-inspect.json"
ss -lntup 2>/dev/null | grep -E '788[0-2]' > "$B/ports-before.txt"
cat > "$B/NOTE.md" <<EOF
# Voice cutover backup ($TS)
Before moving LiveKit from host networking onto happy-selfhost_default and removing public LiveKit
paths. Rollback: see selfhost/cutover/CUTOVER.md "Rollback".
EOF

CB=/home/prep/caddy/trash/${TS}_livekit_removal
mkdir -p "$CB" && cp -a /home/prep/caddy/Caddyfile "$CB/Caddyfile"
cat > "$CB/NOTE.md" <<EOF
# Caddyfile backup before removing public LiveKit paths ($TS)
Removed: the livekit.girthbass.duckdns.org site and the girthbass.duckdns.org handle /livekit* block
(websocket proxy to LiveKit 127.0.0.1:7880 + the retired convai Voice UI on 127.0.0.1:3000).
Rollback: cp $CB/Caddyfile /home/prep/caddy/Caddyfile && caddy reload --config /home/prep/caddy/Caddyfile
EOF
```

### 1b. Merge into `selfhost` (files only; nothing restarts)

The running stacks are started from the main checkout `/home/prep/happy/selfhost` (branch
`selfhost`), so that checkout must hold the new `compose.voice.yml`, `livekit.yaml` and
`docker-compose.yml` (plus the server and web code):

```sh
git -C /home/prep/happy status --short          # must be clean
git -C /home/prep/happy merge --no-ff voice-bridge   # or however the server/web/infra branches are combined
grep -n 'happy-selfhost_default\|127.0.0.1:7880:7880' $SH/compose.voice.yml
grep -n 'LIVEKIT_URL' $SH/docker-compose.yml
```

### 2. Move LiveKit (voice is down from here until step 3 passes, about 10 s)

happy-selfhost must be up, because its network is external to the voice project.

```sh
docker network inspect happy-selfhost_default --format '{{.Name}} ok'
$VOICE up -d livekit                 # recreates only livekit; stt/tts/agent untouched
docker ps --filter name=happy-voice-livekit --format '{{.Status}}'
docker inspect happy-voice-livekit --format '{{.HostConfig.NetworkMode}} {{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}'
docker logs happy-voice-livekit 2>&1 | grep 'starting LiveKit server'   # nodeIP must be the 172.24.x.y above
curl -fsS http://127.0.0.1:7880/; echo                                    # OK
ss -lntup | grep -E '788[0-2]'       # only 127.0.0.1:7880 (docker-proxy); no 7881/7882
```

### 3. Voice agent reconnects

The worker keeps a websocket to `ws://127.0.0.1:7880` and reconnects on its own. Check, and
restart only if it doesn't re-register within ~30 s:

```sh
docker logs --since 2m happy-voice-agent 2>&1 | grep -iE 'registered|connect' | tail -5
# only if needed:  docker restart happy-voice-agent
make -C $SH voice-agent-e2e 2>&1 | tee /tmp/voice-after-move-e2e.txt   # all checks PASS; media host -> container works
```

### 4. happy-server with the bridge

```sh
make -C $SH up                       # rebuilds happy-server, recreates it with LIVEKIT_URL
make -C $SH status
docker exec happy-selfhost-happy-server-1 sh -c 'echo $LIVEKIT_URL; curl -fsS http://livekit:7880/'; echo   # ws://livekit:7880 / OK
```

Deploy the new webapp now (per the web part's instructions).

### 5. Caddy: remove both public LiveKit paths

```sh
bash $SH/cutover/caddyfile-proposed.sh          # writes $SH/cutover/Caddyfile.proposed, prints the diff
diff <(bash $SH/cutover/caddyfile-proposed.sh 2>/dev/null) $SH/cutover/Caddyfile.diff && echo "diff as reviewed"
caddy validate --config $SH/cutover/Caddyfile.proposed --adapter caddyfile
cp $SH/cutover/Caddyfile.proposed /home/prep/caddy/Caddyfile
caddy reload --config /home/prep/caddy/Caddyfile     # same as `systemctl reload caddy` (runs as prep)
```

If `diff as reviewed` doesn't print, the live Caddyfile changed since this was prepared. Read the
printed diff: it must remove only the `handle /livekit*` block and the
`livekit.girthbass.duckdns.org` site.

### 6. ufw (user, sudo)

```sh
sudo ufw status numbered
```

Delete the four rules added on 2026-10-25 for LiveKit media: 7881/tcp and 7882/udp, each from
192.168.2.0/24 and 10.8.0.0/24 (comments `livekit lan` / `livekit vpn`). **Delete from the highest
number down**, because numbers shift after each delete, and re-list between deletes:

```sh
sudo ufw delete <highest livekit rule number>     # answer y
sudo ufw status numbered                           # re-check, repeat for the next one
```

Finally `sudo ufw status | grep -E '788[12]'` must print nothing. If they're open, close the router
forwards for TCP 7881 / UDP 7882 too.

### 7. Checks

```sh
bash $SH/cutover/check-no-public-livekit.sh        # every line PASS
make -C $SH voice-stream-e2e                        # through happy-server; prints latency + jitter
```

`check-no-public-livekit.sh` checks that:

- `https://livekit.girthbass.duckdns.org/` (GET, `/rtc/validate`, websocket upgrade) and
  `https://girthbass.duckdns.org/livekit/` (page, websocket upgrade to `/` and `/rtc/validate`)
  don't return LiveKit's fingerprints (`OK` at `/`, `no permissions to access the room` at
  `/rtc/validate`) or a 101;
- LAN 7880/7881 are closed and no host socket listens on 7881/7882;
- `127.0.0.1:7880` and `happy-server -> livekit:7880` still answer `OK`;
- host -> `<container-ip>:7881` connects;
- LiveKit's nodeIP is the container IP.

Before cutover it reports 10 failures (checked on 2026-10-26), which is the current exposure.

From the Mac (or any LAN/VPN client): `nc -vz 192.168.2.72 7880 7881` and
`nc -vzu 192.168.2.72 7882` must not connect, and voice in Safari must work through 443 only.

## Latency: the two harnesses and how they compare

**`happy-voice-agent/tests/e2e_fake_app.py`** (`make voice-agent-e2e`) joins LiveKit directly as a
`livekit.rtc` participant (WebRTC, Opus) and measures:

- **Speech:** Kokoro `am_michael` speech at 24 kHz, published through an `AudioSource` in 10 ms
  frames.
- **End of speech:** the wall time the clip's last frame plays out of the source buffer
  (`time.time() + source.queued_duration`), minus the clip's trailing quiet samples (|x| <= 300).
- **First agent audio:** the first received agent frame (`AudioStream` at 24 kHz) with RMS > 400
  that starts a new speech segment. A segment ends after 0.6 s under the threshold.
- **Turns:** spoken turns `list_files`, `about`, `allow`, `thanks`. It prints all of them and their
  p50/max.

**`selfhost/scripts/voice-stream-e2e.mjs`** (`make voice-stream-e2e`) uses the same definitions,
utterances, voice and `happy.getConfig` system prompt. It differs in two ways:

- Speech is resampled to 16 kHz and sent as 20 ms PCM16 WebSocket frames, paced in real time.
- "End of speech" is when the frame holding the last loud sample is sent, minus the quiet samples
  after it in that frame.

So the gap between the two numbers is the added transport cost: Caddy, WebSocket, the server bridge,
and its WebRTC leg. That gap is the number the plan's "<= +30 ms" target applies to.

Notes for comparing:

- **Turns:** the stream harness runs `about,thanks` by default. These turns need no tool call, so
  they're the cleanest samples. Compare against the same turns in `e2e_fake_app` output.
  `VOICE_STREAM_ARGS="--turns list_files,about,allow,thanks"` runs all four, but `allow` only makes
  sense after a permission context, which only the Python test sends.
- **LLM variance:** both numbers include LLM time-to-first-token, which varies by hundreds of ms.
  Run each harness 2-3 times, back to back.
- **Jitter (stream harness only):**
  - downlink frame interval p50/p95/max, and |interval - 20 ms| p95;
  - gaps > 40 ms, overall and during agent speech;
  - underruns of a simulated fixed 40 ms playout buffer, which is the web client's starting jitter
    buffer.
  - Silences > 500 ms on the downlink count as stream pauses, not jitter.
- **Exit codes:** 2 means the route is not deployed or unreachable. Before step 4 it prints
  `refused the WebSocket upgrade (502) ... not deployed`.
- **Token:** `HAPPY_TOKEN`, else `~/.happy/access.key` (`token` field, as the happy CLI stores it).
  The script never prints it.

## Rollback

Each step reverses on its own. Undo them in reverse order.

1. **Caddy:**
   `cp /home/prep/caddy/trash/<TS>_livekit_removal/Caddyfile /home/prep/caddy/Caddyfile && caddy reload --config /home/prep/caddy/Caddyfile`
2. **ufw** (user): re-add only if the old direct-LiveKit app path must work again, for example
   `sudo ufw allow from 192.168.2.0/24 to any port 7881 proto tcp comment 'livekit lan'` (and the
   7882/udp and 10.8.0.0/24 variants).
3. **happy-server:**
   - First move the current files to a trash folder with a NOTE.md:
     `mkdir -p /home/prep/happy/trash/<TS2>_rollback && mv $SH/docker-compose.yml /home/prep/happy/trash/<TS2>_rollback/`
   - Restore the old compose file, then rebuild with the old server code:
     `cp /home/prep/happy/trash/<TS>_voice_cutover/docker-compose.yml.before $SH/docker-compose.yml`, then `make -C $SH up`.
     The old image tag is overwritten on rebuild, so a server rollback means checking out the
     previous server commit on a branch and rebuilding.
4. **LiveKit back to host networking:**
   - Move the current `compose.voice.yml` and `livekit.yaml` to the rollback trash folder.
   - Copy back `compose.voice.yml.before` and `livekit.yaml.before` from the backup folder.
   - Run `$VOICE up -d livekit`. Compose recreates it with `network_mode: host`.
   - Then `docker restart happy-voice-agent` if it doesn't reconnect.
   - Check: `make -C $SH voice-agent-e2e`.
5. **Commit the rollback** on `selfhost` as a normal commit. Don't reset or revert history.

## Retired: the `/livekit` "Voice UI"

The `girthbass.duckdns.org` `handle /livekit*` block served two things:

- websocket upgrades went to LiveKit on 127.0.0.1:7880 (with the prefix stripped);
- everything else went through oauth2-proxy to a Next.js app on 127.0.0.1:3000.

That app is `/home/prep/convai/web`:

- It's LiveKit's `agent-starter-react` template with `basePath: '/livekit'`.
- It belongs to an older standalone voice stack in `/home/prep/convai`. That stack also has its own
  `livekit-server` binary, a Parakeet STT on :8989, Kokoro on :8990 and an agent worker.
- Its systemd units are `/home/prep/convai/systemd/*.service`, including `voice-web.service`, and
  none of them are installed.

The related system units `voice-infra.service` and `livekit-agent.service`
(WorkingDirectory `/home/prep/voice`) are both **inactive and disabled**. `/home/prep/voice` no
longer holds their compose file or agent.

Nothing listens on :3000, and the last build log is from 2026-05-15. So today `/livekit` serves a
502 page behind OAuth, while its websocket path still reaches the Happy LiveKit, which is the only
live part. Caddy's access log for that site (since 2026-09-24) has no `/livekit` requests.

The block is removed in step 5 and that UI is retired. Its files under `/home/prep/convai` are left
untouched.
