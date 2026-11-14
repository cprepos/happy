# Addons

`src/addons` holds server features that are not part of the upstream port:
self-hosted voice, the bundled web app, and a heartbeat fix for resumed
sessions. The TypeScript server (`packages/happy-server`) is the reference for
each of them; the compat scenarios below compare the two.

The addons are written to merge with upstream with as few conflicts as
possible:

- They live in their own files. Upstream files call into them at the touch
  points listed below, and nowhere else.
- Settings are read from the environment on first use, and shared state lives
  in statics, so `Config` and `App` are as upstream has them.
- Where an addon needs a private upstream item, it copies it and marks the copy
  (see "Copied items").
- `make upstream-check` checks all three (see "Checking against upstream").

## Features

| Addon | Files | What it does |
|---|---|---|
| voice | `src/addons/voice/` | `GET /v1/voice/config`; `POST /v1/voice/conversations` and `GET /v1/voice/usage` with LiveKit grants and recorded durations as well as ElevenLabs; the `/v1/voice/stream` WebSocket, which bridges the app's audio into a LiveKit room (`bridge.rs`). |
| webapp | `src/addons/webapp.rs` | Serves the web app from `HAPPY_STATIC_DIR`, injects `HAPPY_INJECT_HTML_CONFIG` as `window.__HAPPY_CONFIG__`, keeps the `GET /` server check the apps use, and falls back to `index.html` for app routes. |
| heartbeat | `src/addons/heartbeat.rs` | A session resumed right after it stopped counts from its new owner's first beat, which is written at once. The stop is lifted with upstream's own `resume_session_updates`. |

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

Every upstream file the addons change, with the most lines (added plus
removed, from `git diff --numstat`) the change may take. `upstream-check.sh`
reads this block. `*` means any number.

```touch-points
packages/happy-server-rs/src/main.rs 1
packages/happy-server-rs/src/routes/mod.rs 1
packages/happy-server-rs/src/http.rs 1
packages/happy-server-rs/src/activity.rs 2
packages/happy-server-rs/src/handlers.rs 1
packages/happy-server-rs/Cargo.toml 17
packages/happy-server-rs/Cargo.lock *
```

Each one, and why it is needed:

- **`src/main.rs:21`**, 1 line (`mod addons;`). This declares the module.
- **`src/routes/mod.rs:41`**, 1 line (`crate::addons::register(r, c);`), the
  last line of `routes::register`. It adds the addon routes. Because it runs
  last, it can also replace upstream routes the addons answer differently:
  - `POST /v1/voice/conversations` and `GET /v1/voice/usage`, replaced by voice.
  - `GET /`, replaced by webapp, only when a web app is configured.

  Each replaced route is dropped with `addons::remove_route` before the addon
  route is added. `src/routes/voice.rs` itself is not changed.
- **`src/http.rs:698`**, 1 line. It hands WebSocket upgrades on
  `/v1/voice/stream` to the addon, before upstream's `/v1/updates` upgrade
  handling. This is the only place that sees the raw request with its upgrade.
- **`src/activity.rs:165, 170`**, 1 line each, and **`src/handlers.rs:329`**,
  1 line. These are the heartbeat fix's hooks:
  - `clear_session_updates` reports the stop (`heartbeat::stopped`), and
    `resume_session_updates` reports a lift (`heartbeat::resumed`).
  - `session_alive` asks `heartbeat::alive` before upstream checks the
    session; `false` drops the beat.

  Everything else lives in `heartbeat.rs`. To lift a stop it calls upstream's
  `resume_session_updates`, the same call `POST /v1/sessions` makes, so the
  stop window, the cache and the flush stay upstream's.
- **`Cargo.toml`**, 17 lines. These are tail tables that only the addons use:
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

Private upstream items the addons need are copied, not made public, so the
upstream files stay unchanged. Each copy carries a marker of the form
`// upstream-copy: <file> <item> <hash>`. The hash is the first 16 hex
characters of the sha256 of the item's text, as `scripts/addons/upstream-item.sh`
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

- **`GET /`** stays upstream's route when no web app is configured. The addon
  replaces it only with `HAPPY_STATIC_DIR` set, and then answers the server
  check with upstream's banner text.
- **ElevenLabs.** The voice addon uses upstream's `Config` (`elevenlabs_api`,
  the master secret) and the copied items above.

The rest is kept because upstream covers only part of it:

- **Heartbeats.** Upstream lifts a stop only on `POST /v1/sessions`
  (`resume_session_updates`). A resumed owner that reattaches without that call
  stays ignored for the 60 s window, and its first beat, within the update
  threshold of the stop, is not written. The addon keeps only that decision
  and lifts the stop with upstream's own call. Dropped in favour of upstream:
  the session `active` flag in `ActivityCache` and the stop check rewritten to
  take a connect time (see "Differences" for what that gives up).
- **Voice usage and grants.** Upstream's routes are ElevenLabs-only, with a
  2 h cap. Without the addon's routes, LiveKit grants, recorded durations and
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
  socket counts from its first `session-alive`. The TypeScript server takes the
  time at connect. A socket that connects before a stop but beats only after it
  is therefore treated as the new owner.
- **First beat of an inactive session.** The TypeScript server writes the first
  beat of any session it reads as inactive at once. Here only a resumed
  owner's first beat after a stop is; other inactive sessions follow
  upstream's update threshold. A session is inactive with a recent
  `lastActiveAt` only right after a stop, so this differs only for a session
  set inactive by hand.
- **Web app files.** `@fastify/static` with `wildcard: false` makes one route
  per file found at startup, so files added later 404 or fall back to the SPA.
  The addon reads the directory on each request. Files added later are
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

`scripts/addons/upstream-check.sh` runs three checks:

1. **Touch points.** It fails if an upstream file changes but is not listed in
   the touch-points block, or changes more lines than the block allows.
2. **Merge.** It runs `git merge-tree` of HEAD and the upstream ref and fails
   on any conflict. A conflict in `Cargo.lock` is only a warning.
3. **Copies.** It re-hashes every copied item in the upstream ref and warns
   when one changed, meaning the copy needs a look.

## Toolchain

Upstream's `src/rpc.rs` does not build with rustc 1.94
(`with_label_values(&[&label, result])`). It builds with the rust:1.99 image
upstream's Dockerfile uses. The addons need nothing newer than upstream does.

## Compat scenarios

Each scenario runs against the TypeScript server and this server, and their
transcripts are compared. Run them the same way as upstream's (see
`compat/diff.sh`):

```
compat/withpg.sh compat/diff.sh addons-webapp
```

| Scenario | Env file | Covers |
|---|---|---|
| `addons-voice` | LiveKit set, its server unreachable | REST, grants (JWT claims), usage, stream handshakes, hello checks, close codes |
| `addons-voice-both` | LiveKit and ElevenLabs (the mock) | the same, with both backends offered |
| `addons-voice-bare` | nothing | the same, with voice off |
| `addons-voice-live` | `VOICE_LIVE_ENV=<env with LiveKit keys>`, `VOICE_LIVE_URL` | a real room: ready, the agent joining, audio, RPCs, `end`, and the recorded duration |
| `addons-webapp` | `testdata/addons-webapp` with injected config | server check, files, traversal, conditional and range requests, SPA fallback, API paths |
| `addons-webapp-plain` | the same directory, without config | the same |
| `addons-webapp-noindex` | a directory without `index.html` | no web app; upstream's `GET /` |
| `addons-heartbeat` | none | stop window, resumed owner and its first beat written |
