# happyify: Claude desktop sessions in Happy

## Problem

Sessions started in the Claude desktop app's Code tab never reach Happy. To
continue one from the phone today you have to find its Claude session id and
run `happy claude --resume <id>`. That starts a second Claude process on the
same transcript. The desktop process still holds the old history in memory, so
the conversation forks the next time either side writes.

Goal: every desktop Code session shows up in Happy on its own, updates live,
and takes messages from the phone **inside the desktop's own Claude process**
so there is only ever one writer.

Out of scope: claude.ai / desktop Chat-tab conversations. They exist only on
Anthropic's servers; there is nothing local to mirror.

## What we verified (2026-11-02, desktop bundling Claude Code 2.1.309)

Tested with a throwaway plugin (`~/.happyify-test/marketplace`, installed as
`happyify@happyify-local`, user scope).

| Question | Result |
|---|---|
| Does the desktop load user-scope plugins? | **Yes.** Hooks run inside its Claude process with `CLAUDE_CODE_ENTRYPOINT=claude-desktop`. |
| Does SessionStart give us what we need? | **Yes.** `session_id`, `transcript_path`, `cwd`. |
| Can we write to the session's context? | **Yes.** SessionStart / UserPromptSubmit `additionalContext`. |
| Can we write to the desktop's stdin? | **No.** It spawns `claude --input-format stream-json --permission-prompt-tool=stdio` on a pipe it owns. |
| Does the desktop notice outside edits to the transcript? | **No transcript watcher found** in the app bundle. It reads `~/.claude/projects/*.jsonl` only when listing/opening sessions. |
| Can a hook wake an idle session? | **Yes.** A `Stop` hook with `"asyncRewake": true` that exits 2 starts a new turn. The turn shows live in the desktop window. |

### The catch with asyncRewake

Claude Code records the woken turn as a hook result, not a user message:

```
<task-notification><summary>Stop hook feedback</summary></task-notification>
<system-reminder>Stop hook blocking error from command "Stop": <our text></system-reminder>
```

The model is also told it is *"an automated background-task event, NOT a
message from the user"* and must not be read as approval. That framing is
deliberate and we should not try to get around it. What follows from it:

- Ordinary requests ("run the tests", "explain this") work.
- Anything that needs the user's authority does not: confirming a destructive
  step, answering "should I proceed?", approving a plan. Claude will rightly
  ask again at the desktop.

So asyncRewake is a **working fallback**, not the real phone→desktop channel.

## Channels: the proper inbound path

[Channels](https://code.claude.com/docs/en/channels) (research preview) let an
MCP server that declares the `claude/channel` capability push messages into a
running session. A reply tool lets Claude answer back through the same server.
This is Anthropic's supported design for chat bridges. **Unverified:** whether
the model treats a channel message as coming from the user, or treats it as
untrusted input the way it treats rewake. Phase 0 checks this.

Constraints:
- The session has to be started with `--channels plugin:happyify@<marketplace>`.
- Our channel is not on the default allowlist, so it also needs
  `--dangerously-load-development-channels` until it is.
- The desktop's spawner does pass `--channels` through (`options.channels` in
  the app bundle). **Unknown:** whether the desktop UI or config lets a user
  turn on a custom channel. Phase 0 answers this.

## Phase 0 results (2026-11-02)

| Spike | Result |
|---|---|
| `claude --desktop` with a prompt | **No.** It refuses: "--desktop doesn't take a prompt yet". With no prompt it opens the folder in the desktop, but no Claude process starts until someone types in the app. |
| `claude --desktop --resume <id>` | **Works.** The desktop starts its Claude process right away, and SessionStart fires with `entrypoint=claude-desktop`. |
| Seeding a session without a model turn | **Works.** `claude -p "/cost"` writes a session file holding only a local-command record (`/usage`). No assistant turn and no API call. Use `--session-id <uuid>` to choose the id. |
| `asyncRewake` on **SessionStart** | **Works.** A freshly resumed desktop session ran the injected message without any typed turn. Phone-started sessions go: seed with `/cost` → `--desktop --resume` → first prompt delivered by the SessionStart rewake. |
| Custom channels in the desktop | **No.** The desktop passes `--channels` but never `--dangerously-load-development-channels`, so a non-allowlisted channel can't load. Rewake is the inbound path. |
| PermissionRequest hook in the desktop | **Fires** (`tool` request from an injected turn). Not yet tested: whether a hook decision suppresses the desktop's own dialog. The test was blocked because the test plugin is user-scoped and an auto-allow hook would also approve tools in every other Claude Code session. The real hook must be scoped to adopted desktop sessions and answer only with a decision relayed from the phone, never auto-allow. |
| SessionEnd | **Fires** (seen on `-p` exit). Use it to archive the mirror. |

## Design

```
 Claude desktop app
   └─ claude (bundled CLI) ── happyify plugin
         │  hooks: SessionStart / UserPromptSubmit / Stop(asyncRewake) / PermissionRequest
         │  mcp:   happyify channel server (when --channels is available)
         ▼  HTTP 127.0.0.1
 happy daemon  ──spawns──▶  happy attach <claudeSessionId>   (one per desktop session)
                                 ├─ Happy session (server + socket)
                                 ├─ sessionScanner on transcript_path   → phone
                                 └─ inbound queue  ◀── phone messages
                                       └─ handed to the waiting hook / channel
```

### 1. Plugin (`packages/happyify-plugin/`)

A Claude Code plugin served from a marketplace in our repo. Components:

- **SessionStart hook.** POSTs `{session_id, transcript_path, cwd, entrypoint,
  pid}` to the daemon's `/adopt-session`. Runs for every entrypoint, so CLI
  sessions get adopted too unless we filter. Default: adopt only
  `claude-desktop`, and skip any session that Happy itself spawned (those
  already carry `HAPPY_*` env).
- **UserPromptSubmit hook.** Tells the daemon the desktop is busy. Its output
  can carry phone messages that are still queued as `additionalContext` (same
  trust level as rewake).
- **Stop hook, `asyncRewake: true`.** Long-polls the daemon
  (`GET /inbox/<sid>?wait=600`). If a message comes back it prints it and exits
  2. On timeout it exits 0 and re-arms on the next Stop. This is the fallback
  inbound path.
- **Channel MCP server.** Same inbox, pushed as `notifications/claude/channel`,
  with a `reply` tool. Used whenever the session was started with channels;
  when it is active the Stop hook stays out of the way.
- **PermissionRequest hook (phase 3).** Forwards permission prompts to the
  phone so they can be answered remotely. Needs checking: whether the desktop
  shows its own dialog anyway.

The hooks stay a thin `node` script that only talks to `127.0.0.1`. All logic
lives in happy-cli.

### 2. Daemon: `/adopt-session`

New route in `packages/happy-cli/src/daemon/controlServer.ts`, next to
`/session-started`:

- Idempotent on `claudeSessionId`. A second SessionStart (resume, `/clear`,
  compact) updates the existing mirror instead of creating another.
- Spawns `happy attach <claudeSessionId> --transcript <path> --cwd <cwd>
  --host-pid <pid>` the same way `/spawn-session` spawns `happy claude`, so it
  gets tracked through the existing `notifyDaemonSessionStarted` path.
- Also serves `/inbox/:sid` (long-poll) and `/busy/:sid` for the hooks, proxying
  to the right attach process.

Why a separate process instead of running inside the daemon: `runClaude` already
owns the session lifecycle (`getOrCreateSession`, the socket, keepAlive,
metadata, crash handling). The attach mode reuses that wholesale, and the
daemon keeps its existing role of spawning and tracking.

### 3. `happy attach`: mirror without spawning

A new mode in happy-cli that is `runClaude` minus the launcher loop:

- `getOrCreateSession` with metadata `{flavor: 'claude', startedBy:
  'desktop', hostPid, claudeSessionId, path: cwd}`. `startedBy` is
  `'daemon' | 'terminal'` today (`src/api/types.ts`), so this adds a value. The
  app can then label these "Desktop".
- `createSessionScanner` (`src/claude/utils/sessionScanner.ts`) on the
  transcript, forwarding through `sendClaudeSessionMessageFromLocalTranscript`,
  same as `claudeLocalLauncher`. Phone messages are recognised when they come
  back through the transcript (the rewake `Stop hook feedback` wrapper, or the
  channel envelope), are mapped back to the phone message they came from, and
  are not posted twice.
- `session.onUserMessage` → inbound queue, waiting for the hook or channel to
  claim it. Nothing is sent to a Claude process directly.
- `keepAlive(thinking, 'local')` driven by the UserPromptSubmit / Stop events
  (busy vs idle).
- Exits and marks the session ended when `hostPid` dies (the desktop closed the
  session or quit).

### 4. Phone app

Minimal changes:
- Show a "Desktop" badge from `metadata.startedBy`.
- When the inbound path is rewake (not a channel), show a one-line note in the
  composer: messages run as background requests; approvals happen on the
  desktop.
- Messages sent while the desktop is mid-turn stay queued. Show them as
  "queued until the desktop is idle". Check whether the existing
  queued-message UI can show this.

## Edge cases

- **New session, no turn yet.** The rewake waiter only starts after the first
  Stop. Try `asyncRewake` on SessionStart (untested). Otherwise the phone can
  only message after the first desktop turn.
- **Several waiters.** Every Stop spawns one. The daemon delivers to the newest
  waiter only, and older ones are released with exit 0.
- **Waiter timeout.** Hook timeout 600s. An idle session longer than that loses
  its waiter until the next turn. A channel has no such gap, which is another
  reason channels are the target.
- **Desktop resumes into a new session id** (fork, `/clear`). SessionStart fires
  with the new id. The daemon re-points the existing mirror; this matches what
  `sessionScanner.onNewSession` already handles.
- **Plugin loaded in Happy's own sessions.** It is a user-scope plugin, so it
  runs inside sessions that `happy claude` spawned as well. The hooks have to
  no-op when `HAPPY_*` env is present, or Happy sessions would be adopted twice.
- **Daemon not running.** The hooks fail closed and silently (exit 0, nothing
  in context). A desktop session must never break because Happy is down.

## Phases

0. **Channel check** (≈1h). Find out whether a desktop session can be started
   with a custom channel, and how channel messages are framed to the model. Also try `asyncRewake` on SessionStart and the
   PermissionRequest hook in the desktop. The results decide what phase 2
   builds on.
1. **Mirror** (desktop → phone). Plugin SessionStart hook, `/adopt-session`,
   `happy attach` with the scanner, Desktop badge. Read-only from the phone,
   and useful on its own.
2. **Inbound** (phone → desktop). Inbox + Stop-rewake fallback, plus a channel
   server if phase 0 says it is reachable.
3. **Permissions** from the phone through PermissionRequest.
4. **Packaging.** Marketplace in the repo; `happy install-desktop-plugin` runs
   `claude plugin marketplace add` and `claude plugin install`.

## Testing

- Unit: `/adopt-session` idempotency, inbox newest-waiter delivery, how phone
  messages coming back in the transcript are recognised and de-duplicated
  (fixtures from the real rewake transcript lines recorded in the test above).
- Integration: `claude -p` with `--plugin-dir` drives SessionStart/Stop/rewake
  without the desktop (`-p` stays alive while the rewake hook waits, which
  makes it scriptable).
- Manual: `claude --desktop --resume <id>` (needs a TTY: `script -q /dev/null
  claude --desktop ...`) opens a known session in the desktop for end-to-end
  checks.
