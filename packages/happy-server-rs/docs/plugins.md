# Plugins

`src/plugins` holds server features that are not part of the upstream port:
self-hosted voice, the bundled web app, and a heartbeat fix for resumed
sessions. The TypeScript server (`packages/happy-server`) is the reference for
each of them; the compat scenarios below compare the two.

The plugins are written to merge with upstream with as few conflicts as
possible:

- They live in their own files. Upstream files call into them at the touch
  points listed below, and nowhere else.
- Settings are read from the environment on first use, and shared state lives
  in statics, so `Config` and `App` are as upstream has them.
- Where a plugin needs a private upstream item, it copies it and marks the copy
  (see "Copied items").
- `make upstream-check` checks all three (see "Checking against upstream").

## Features

| Plugin | Files | What it does |
|---|---|---|
| voice | `src/plugins/voice/` | `GET /v1/voice/config`; `POST /v1/voice/conversations` and `GET /v1/voice/usage` with LiveKit grants and recorded durations as well as ElevenLabs; the `/v1/voice/stream` WebSocket, which bridges the app's audio into a LiveKit room (`bridge.rs`). |
| webapp | `src/plugins/webapp.rs` | Serves the web app from `HAPPY_STATIC_DIR`, injects `HAPPY_INJECT_HTML_CONFIG` as `window.__HAPPY_CONFIG__`, keeps the `GET /` server check the apps use, and falls back to `index.html` for app routes. |
| heartbeat | `src/plugins/heartbeat.rs` | A session resumed right after it stopped counts from its new owner's first beat, and a session the server knows is inactive writes its first beat at once. |

Environment:

| Variable | Used by |
|---|---|
| `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | voice: LiveKit grants and the stream. Without them LiveKit is off. |
| `LIVEKIT_URL` | voice: the LiveKit server the stream joins (default `ws://livekit:7880`, as the TypeScript server). |
| `LIVEKIT_PUBLIC_URL` | voice: the URL handed to apps in grants. Required with the LiveKit keys; it has no default. Without it the server logs an error at startup and `POST /v1/voice/conversations` answers 500 for LiveKit grants. The stream does not need it. |
| `VOICE_BACKENDS` | voice: offered backends, e.g. `elevenlabs,stream`. |
| `ELEVENLABS_API_KEY` | voice: the ElevenLabs backend, as upstream. |
| `HAPPY_STATIC_DIR` | webapp: the built web app. Needs an `index.html`. |
| `HAPPY_INJECT_HTML_CONFIG` | webapp: a JSON value for `window.__HAPPY_CONFIG__`. |

## Touch points

Every upstream file the plugins change, with the most lines (added plus
removed, from `git diff --numstat`) the change may take. `upstream-check.sh`
reads this block. `*` means any number.

```touch-points
packages/happy-server-rs/src/main.rs 1
packages/happy-server-rs/src/routes/mod.rs 1
packages/happy-server-rs/src/http.rs 3
packages/happy-server-rs/src/activity.rs 25
packages/happy-server-rs/src/handlers.rs 6
packages/happy-server-rs/Cargo.toml 17
packages/happy-server-rs/Cargo.lock *
```

Each one, and why it is needed:

- **`src/main.rs:21`**, 1 line (`mod plugins;`). This declares the module.
- **`src/routes/mod.rs:41`**, 1 line (`crate::plugins::register(r, c);`), the
  last line of `routes::register`. It adds the plugin routes. Because it runs
  last, it can also replace upstream routes the plugins answer differently:
  - `POST /v1/voice/conversations` and `GET /v1/voice/usage`, replaced by voice.
  - `GET /`, replaced by webapp, only when a web app is configured.

  Each replaced route is dropped with `plugins::remove_route` before the plugin
  route is added. `src/routes/voice.rs` itself is not changed.
- **`src/http.rs:698-700`**, 3 lines. These hand WebSocket upgrades on
  `/v1/voice/stream` to the plugin, before upstream's `/v1/updates` upgrade
  handling. This is the only place that sees the raw request with its upgrade.
- **`src/activity.rs`**, 25 lines, and **`src/handlers.rs:155, 330-334`**, 6
  lines. These are the heartbeat fix.
  - `SessionEntry` gets an `active` flag. It is read with `lastActiveAt` and set
    by the flush.
  - `is_session_stopped`, `is_session_valid` and `queue_session_update` take the
    socket's `connected_at`.
  - The stop check asks `heartbeat::stop_applies`, and the update threshold asks
    `heartbeat::should_queue`.
  - In `handlers.rs`, `dispatch` reports each socket (`heartbeat::seen`), and
    `session_alive` passes `connected_at` on.

  The decisions live in `heartbeat.rs`. What is left in upstream files is the
  plumbing, which has no place outside them.

  A smaller variant was weighed and rejected: a plugin-side map consulted only
  in `session_alive`. It would let a stale owner's beat through during the
  resume window, which is the case the fix exists to prevent.
- **`Cargo.toml`**, 17 lines. These are tail tables that only the plugins use:
  - `[target.'cfg(all())'.dependencies]` holds livekit and its pins.
  - `[target.'cfg(all())'.build-dependencies]` holds `webrtc-sys-build`.

  The `cfg(all())` target tables always apply, but are separate from
  upstream's `[dependencies]`, so upstream edits there do not conflict. Why the
  pins are needed:
  - livekit `=0.8.0` with `webrtc-sys =0.3.42` is the newest pair whose
    prebuilt libwebrtc links against libstdc++ and builds with gcc. 0.3.43 and
    later need clang 21 or newer.
  - The `livekit-*` patch pins keep 0.8.0 compiling.
- **`Cargo.lock`**. It is regenerated. On a merge conflict, take upstream's and
  run `cargo update -w`.

Outside the crate:

- `packages/happy-server/prisma/migrations/20261025120000_voice_conversation_livekit`
  is the same migration the TypeScript server ships. It lets
  `VoiceConversation` hold LiveKit rooms (`roomName`, `sessionId`, `language`;
  the ElevenLabs id becomes optional).
- `schema.prisma` is not changed, since the Rust server does not read it.

## Copied items

Private upstream items the plugins need are copied, not made public, so the
upstream files stay unchanged. Each copy carries a marker of the form
`// upstream-copy: <file> <item> <hash>`. The hash is the first 16 hex
characters of the sha256 of the item's text, as `scripts/plugins/upstream-item.sh`
extracts it.

| Copy | Original | Hash |
|---|---|---|
| `voice/elevenlabs.rs` `CONVERSATION_ID` | `src/routes/voice.rs` | b6397e5c0f020b5d |
| `voice/elevenlabs.rs` `eleven_user_id` | `src/routes/voice.rs` | d0bd104774f330a1 |
| `voice/elevenlabs.rs` `Token` | `src/routes/voice.rs` | c13c4141c94633d0 |
| `voice/elevenlabs.rs` `conversation_token` | `src/routes/voice.rs` | 92c48cd856f2f341 |
| `voice/stream.rs` `abort_raw` | `src/engine.rs` | b6b265f957bd7c00 |
| `voice/stream.rs` `ws_key_valid` | `src/engine.rs` | dd1fed31dd050a48 |

`voice/usage.rs` pages ElevenLabs' history as upstream's private `voice_usage`
does, but it stops at the 5 h cap the grant checks against, not upstream's
2 h. It is therefore not a copy and carries no marker.

## What upstream already covers

Upstream code is used wherever it does the whole job:

- **`GET /`** stays upstream's route when no web app is configured. The plugin
  replaces it only with `HAPPY_STATIC_DIR` set, and then answers the server
  check with upstream's banner text.
- **ElevenLabs.** The voice plugin uses upstream's `Config` (`elevenlabs_api`,
  the master secret) and the copied items above.

The rest is kept because upstream covers only part of it:

- **Heartbeats.** Upstream lifts a stop only on `POST /v1/sessions`
  (`resume_session_updates`). A resumed owner that reattaches without that call
  stays ignored for the 60 s window. Upstream also writes a session's first
  beat only after the update threshold; it already does this for machines, but
  not for sessions.
- **Voice usage and grants.** Upstream's routes are ElevenLabs-only, with a
  2 h cap. Without the plugin's routes, LiveKit grants, recorded durations and
  the 5 h cap would be lost.
- **Web app.** Upstream has no static serving.
  `docs/plans/happy-serve-self-host.md` plans one, but none is implemented at
  a78d7ca59.

## Differences from the TypeScript server

- **`LIVEKIT_PUBLIC_URL`** has no default. The TypeScript server falls back
  to one particular host; this server answers a LiveKit grant with
  `500 {"error":"LIVEKIT_PUBLIC_URL is not configured"}` instead, and logs why
  at startup.

- **Heartbeat connect time.** `SocketHandle` has no connect timestamp, so a
  socket counts as connected when it sends its first event (`heartbeat::seen`).
  The TypeScript server takes the time at connect. A socket that connects
  before a stop but sends nothing until after it is therefore treated as new.
- **Web app files.** `@fastify/static` with `wildcard: false` makes one route
  per file found at startup, so files added later 404 or fall back to the SPA.
  The plugin reads the directory on each request. Files added later are
  served; otherwise it routes the same way:
  - dot files are skipped
  - a directory needs a trailing slash
  - `%2f` matches no file
- **A 304 answer to `HEAD`** carries `Content-Length: 0`. Upstream's response
  writer always sets the header, while `send` leaves it out.
- **Dates** in `If-Modified-Since`, `If-Unmodified-Since` and `If-Range` are
  parsed as RFC 2822/HTTP dates. `Date.parse` also takes other formats.

## Checking against upstream

```
make upstream-check                 # against origin/main
make upstream-check UPSTREAM=<ref>
```

`scripts/plugins/upstream-check.sh` runs three checks:

1. **Touch points.** It fails if an upstream file changes but is not listed in
   the touch-points block, or changes more lines than the block allows.
2. **Merge.** It runs `git merge-tree` of HEAD and the upstream ref and fails
   on any conflict. A conflict in `Cargo.lock` is only a warning.
3. **Copies.** It re-hashes every copied item in the upstream ref and warns
   when one changed, meaning the copy needs a look.

## Toolchain

Upstream's `src/rpc.rs` does not build with rustc 1.94
(`with_label_values(&[&label, result])`). It builds with the rust:1.99 image
upstream's Dockerfile uses. The plugins need nothing newer than upstream does.

## Compat scenarios

Each scenario runs against the TypeScript server and this server, and their
transcripts are compared. Run them the same way as upstream's (see
`compat/diff.sh`):

```
compat/withpg.sh compat/diff.sh plugins-webapp
```

| Scenario | Env file | Covers |
|---|---|---|
| `plugins-voice` | LiveKit set, its server unreachable | REST, grants (JWT claims), usage, stream handshakes, hello checks, close codes |
| `plugins-voice-both` | LiveKit and ElevenLabs (the mock) | the same, with both backends offered |
| `plugins-voice-bare` | nothing | the same, with voice off |
| `plugins-voice-live` | `VOICE_LIVE_ENV=<env with LiveKit keys>`, `VOICE_LIVE_URL` | a real room: ready, the agent joining, audio, RPCs, `end`, and the recorded duration |
| `plugins-webapp` | `testdata/plugins-webapp` with injected config | server check, files, traversal, conditional and range requests, SPA fallback, API paths |
| `plugins-webapp-plain` | the same directory, without config | the same |
| `plugins-webapp-noindex` | a directory without `index.html` | no web app; upstream's `GET /` |
| `plugins-heartbeat` | none | stop window, resumed owner, first beat of an inactive session |
