# Android Parity With the Native iOS App

Status: **PLANNED — not started**

## Context

The native Android app (`packages/happy-android`) is behind the native iOS app
(`packages/happy-ios`). Almost all of the gap is work this fork added to iOS.
On upstream's own features the two apps are about even: upstream (slopus/happy)
builds iOS and Android side by side, and Android is slightly ahead in places
(foldable layouts, the `benchmark/` module).

Measured at fork/main 0f1ad8972 against upstream 5e9f98e05:

| | Fork-only diff vs upstream |
|---|---|
| iOS | 165 commits, 378 files, +27,678 / −1,000 |
| Android | 1 commit, 15 files, +425 / −32 (generated strings, one test, ElevenLabs relay voice turned back on) |

Total estimate: **about 2–4 months for one engineer**. The live browser and
local voice are most of it.

## What Android is behind on

### Fork features (iOS only today)

| # | Feature | Android today | Size |
|---|---|---|---|
| 1 | Live browser | nothing | XL, about 4–6 wks |
| 2 | Local voice (stream backend) and voice settings | ElevenLabs only | L, about 3–4 wks |
| 3 | opencode harness | not an agent type | M |
| 4 | Claude Desktop harness | nothing | M |
| 5 | Subagents and running-agents panel | no parsing of the events | M |
| 6 | Relay links through the paired computer | opens them on the phone | M |
| 7 | Chat-load reliability (retry on reopen, Retry button, shared connect) | no | S–M |
| 8 | Inline question polish | upstream's basic form | S–M |
| 9 | Group home list by computer, harness names on rows | strings exist, unused | S |
| 10 | Mode row before the first send, keyboard send shortcut | no | S |
| 11 | Self-host build flavor and APK install link | upstream server URL is hardcoded | S |

Not applicable on Android: the iPad keyboard-bar work (`ChatUltraKeyboard`,
`KeyboardFrames`, `KeyboardCover`) and the WebKit loopback alias
(`BrowserLoopback.swift`). Android's `ProxyController` already routes localhost
through `BrowserProxy` (`removeImplicitRules()` in `ui/browser/BrowserView.kt`).

### Upstream features

There is no meaningful gap. The Mac app and the App Clip exist only on iOS, by
nature.

### Neither app

The vault (Vaultwarden filler, logins and passwords) has no screen in either
app. It is agent-side only: `selfhost/vault`, `browser-stack/vault-mcp` and
`browser-stack/browser/filler`.

## Phase 0: Prerequisites

- **Android SDK on the dev box.** Gradle 9.8.1 (wrapper, cached) and JDK 21 are
  present. The SDK is not: no `ANDROID_HOME`, `sdkmanager`, `aapt2` or `adb`.
  Install the command-line tools under the user's home (no root), write
  `packages/happy-android/local.properties`, and add a Make target that builds
  and runs `testDebugUnitTest`.
- **CI.** `.github/workflows/happy-android.yml` already runs
  `assembleDebug assembleRelease testDebugUnitTest :crypto:test` on
  `ubuntu-latest`. Confirm that it runs on the fork.
- **Self-host build flavor (#11).** `app/build.gradle.kts:106` hardcodes
  `DEFAULT_SERVER_URL` to upstream. Add a Gradle property or flavor with its
  own applicationId that bakes in `https://happy.girthbass.duckdns.org` and
  turns push off, mirroring iOS `Environment/SelfHostBuild.swift` and
  `project.selfhost.yml`.
- **Install path.** Serve a signed APK next to the iOS OTA page (Caddy
  `/ota/<hash>`, see `.agents/skills/happy-ios-ota/SKILL.md`). Write the matching
  skill so device installs are repeatable.

## Phase 1: Live browser (#1)

The largest item, and the most used. The bridge is done, so this is app work.

**Contract to mirror** (`browser-stack/browser/bridge/lib/app.mjs`, header lines 4–22;
tests in `bridge/test/*.test.mjs`; routing in
`packages/happy-ios/docs/browser-proxy.md`):

- **Chat key:** `sha256("<source>:<id>")`, first 32 hex characters
  (`bridge/mcp.mjs:217-219`).
  - The app tries `happy:<happySessionId>` first, then `agent:<agentId>`.
  - A bot tries its mirrored Happy session first, then its agent.
  - Mirror `LiveBrowser.swift:87-102` and `LiveBrowserChatIdentity.keys`.
- **Endpoints:**
  - `GET /live/chat/<key>` returns the link plus `live`, `pod` and the state, or
    404.
  - `GET /live/<id>/state` returns
    `{status, reason, url, title, last_action, pod, live, live_reason}`.
  - `GET /live/<id>/frame.jpg` (503 while asleep).
  - `POST /live/<id>/take` returns `{...state, novnc_url}`, or 202 while waking.
  - `POST /live/<id>/release` and `POST /live/<id>/end`.
  - `POST /live/<id>/nav {action: back|forward|reload|goto, url?}` returns 200,
    or 400 bad_url, 409 not_in_control, 404/410, 503 asleep or 502.
  - `/live/<id>/vnc/*` and the websockify WebSocket.
- **`live` is the only truth.** The red indicator follows
  `runs = live ?? (!ended && !asleep)`. Never show a red indicator for a dead
  browser: the phantom-browser bug fixed on iOS.
- **Transport:** the bridge is at `http://localhost:6090` on its own computer and
  `http://192.168.2.72:6090` (its LAN listener) from another; a link names which
  (`LiveBrowserLink.origins`). Either is reached through the host-workspace tunnel. Android's
  `browser/BrowserProxy.kt`, `BrowserFetcher.kt` and `BrowserTunnel.kt` can
  carry it.
- **Link detection:** `(http://localhost:6090|http://192\.168\.2\.72:6090)/live/([0-9a-f]{32})`.

**Work, in order:**
1. **Core (L).** Port `HappyCore/Browser/{LiveBrowser, LiveBrowserChatIdentity,
   LiveBrowserChatWatch, LiveBrowserFeed}.swift`: the key lookup, state polling,
   frame polling, and the asleep, waking and dead states. Port the iOS tests
   `Tests/HappyCoreTests/LiveBrowser{Chat,Feed,FeedStall,Workspace}Tests.swift`
   as unit-test fixtures first.
2. **One shared dock (L–XL).** Build a single component used by all three chat
   surfaces: session chat, agent chat and bot chat. Do not build three copies;
   iOS learned this the hard way (`LiveBrowserDock.swift` and
   `LiveBrowserDockRoute.swift`). It covers the mini player, full screen, the
   red line, the inline card for agent-driven browsers, links turned into
   chips, and End browser.
3. **Take-over (M).** Take control and release in a noVNC WebView, recover when
   noVNC drops, and back, forward, reload and an address bar through
   `POST /nav`.
4. **Browser tool rows (S).** Render `browser_*` tools as a "Browser" row in
   `chat/tools/ToolDisplay.kt`, matching iOS `ChatToolDisplay.browserActivity`.
5. **Strings.** The live-browser strings are hard-coded in iOS
   (`HappyUI/Strings/Browser.swift`, `NativeTranslations+Browser.swift`). Move
   them into `packages/happy-i18n` so both apps share them.

## Phase 2: Local voice (#2)

- **Stream backend (L).** The phone opens a WebSocket to happy-server, which
  joins LiveKit, with local Kokoro TTS and Nemotron STT behind it.
  - **Contract** (`packages/happy-wire/src/voiceStream.ts`):
    - `/v1/voice/stream`, opened with `hello` and answered by `ready` or `error`.
    - Audio is binary PCM16 LE mono in 20 ms frames: 16 kHz up, 24 kHz down.
    - Data topics `happy.text` and `happy.context`.
    - RPCs `happy.getConfig`, `sendMessageToSession` and
      `processPermissionRequest`.
  - **Backends:** `GET /v1/voice/config` returns `{backends, defaultBackend}`
    (`happy-server/sources/app/api/routes/voiceRoutes.ts`).
  - **iOS reference:** `HappyCore/Voice/{VoiceBackend, VoiceStreamClient,
    VoiceDsp, VoicePlaybackScheduler, VoiceSystemPrompt, VoiceContextRepeat,
    VoiceActivityTracker}.swift` and `HappyUI/Voice/{StreamVoiceConnection,
    VoiceAudioEngine, VoicePlaybackBuffer}.swift`.
- **Voice settings (M).** Choosing the service, the Kokoro preset picker, a
  voice per chat on the session info screen, a minimized voice strip, and calls
  that survive a locked phone (a foreground service on Android).
  - Honour the synced settings `voiceBackend`, `voiceAssistantVoice` and
    `voiceBySession` (`HappyCore/Settings/AccountSettings.swift:110-114`).
  - The `settings_voice_voice_picker_*` strings are already generated into
    Android resources.

## Phase 3: Harnesses and agents (#3–#5)

- **opencode (M).** Add it to `AgentType` (`model/MachineChoices.kt`), with its
  mode catalog, first-message mode, questions and resume. iOS reference:
  `Harness/OpencodeHarness.swift` and `Composer/OpencodeModes.swift`. The
  `agent_input_permission_mode_opencode_*` strings exist.
- **Claude Desktop (M).** The harness, avatar badge, a composer without pickers,
  archived chats with Resume, and on-demand history through the
  `desktop-load-history` RPC and `metadata.desktopHistory.before`. iOS
  reference: `Harness/ClaudeDesktopHarness.swift` and
  `Harness/DesktopHistory.swift`. The CLI side already exists.
- **Harness catalog (S).** Harness names on rows (`HarnessCatalog.swift`,
  `HomeRowHarnessLayout.swift`). Confirm that agy resume works.
- **Subagents (M).** Parse the fork's wire additions in
  `happy-wire/src/sessionProtocol.ts`:
  - `start.{subagentType, model, prompt, spawnDepth, parentTaskId}`;
  - `stop.{status, summary, tokens, toolUses, durationMs}`;
  - the new `progress` and `agents` events.

  Then fold subagents in the transcript and add the running-agents panel. iOS
  reference: `Chat/SubagentFold.swift` and `ChatDisplay/RigActivityBarContent.swift`.
- **New bots and tasks (S).** They start on the computer's default model, and
  Codex defaults to the account's own model.

## Phase 4: Chat and links (#6–#10)

- **Relay links (M).** Links in a Happy CLI chat open through the paired
  computer's host workspace, and the user is asked which computer when there is
  more than one. iOS reference: `LegacyLinkRoute.swift`,
  `LegacyBrowserRoute.swift`, `LegacyLinkOpening.swift` and `MachineName.swift`.
  Android's `ui/browser/Links.kt` (`LinkOpener.legacy`) is the place to change.
- **Chat-load reliability (S–M).** Port the three iOS fixes from 2026-11-05:
  - re-read a chat whose load failed or never finished when it is reopened, or
    when the app returns;
  - show the error with a Retry button instead of an empty chat;
  - one cancelled waiter must not cancel a connect that others share.

  Check whether Android's agent chat cache has the same "failed once, cached
  forever" shape.
- **Questions (S–M).** Dismiss with an X, a free-text field, a loader, and
  saying when an answer is refused (`InlineQuestionLayout.swift`).
- **Small items (S).** Group the home list by computer
  (`sessions_filter_group_by_machine`), the mode row before the first send
  (`LegacyComposeMode.swift`), and Ctrl/Meta+Enter to send.

## Order and rules

1. **Order:** Phase 0, then Phase 1, then the rest by how much they are
   missed. Each item ships as its own branch with a device install for hand
   testing first; long suites run afterwards as regression.
2. **Reuse:** reuse the server, bridge and wire contracts as they are. Any
   change to a contract lands on both apps.
3. **Strings:** new strings go into `packages/happy-i18n`, not hard-coded per
   app.
4. **Repo rules:** pushes go to `fork`, never `origin` (see AGENTS.md).
