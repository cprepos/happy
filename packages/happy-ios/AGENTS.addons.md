# happy-ios: fork rules

These are this fork's (`cprepos/happy`) changes to `AGENTS.md` in this
directory, which is kept as upstream's text so upstream merges apply cleanly.
Each section says where it goes in `AGENTS.md` and whether it replaces
upstream's text there or adds to it. Where this file and `AGENTS.md` differ,
this file wins.

## Scope: voice (replaces upstream's "Voice in a Happy account's sessions is off" bullet)

This bullet replaces upstream's `LegacyVoice` bullet in Scope ("Voice in a
Happy account's sessions is off"): in this fork voice is on.

- **Voice mode is included by the current product request, on two backends.**
  `GET /v1/voice/config` says which the account's server offers (a 404 is an
  older server, treated as ElevenLabs only; any other failure fails the call),
  and the synced `voiceBackend` setting chooses; null follows the server's
  default. See the repo's `docs/voice-architecture.md`.
  - **`stream`.** `VoiceStreamClient` speaks the server's `/v1/voice/stream`,
    the protocol happy-app uses, and `StreamVoiceConnection` joins it to
    `VoiceAudioEngine`, on `AVAudioEngine`. LiveKit stays behind the server, so
    this needs no SDK.
  - **`elevenlabs`.** The official ElevenLabs Swift SDK provides WebRTC
    microphone and speaker transport. Happy's authenticated backend alone
    grants its free or subscribed allowance; a missing client RevenueCat
    configuration never prevents a valid grant. A user's own agent needs no
    grant.

  On both, voice stops on background, account switch/sign-out, audio
  interruption or headphone removal, and client tools use the existing outbox
  and permission RPCs.
  In this fork `LegacyVoice.isEnabled` defaults to on, so the relay voice
  above stays reachable; upstream ships it off.

## Scope: push signing (replaces upstream's "Signing." sub-bullet)

This replaces the "Signing." sub-bullet under Scope's push notifications
bullet; it adds the self-host sentence to upstream's text.

  - **Signing.** All three variants have `aps-environment` "development"
    and the `remote-notification` background mode, as the RN app's
    expo-notifications plugin writes them. Distribution signing swaps in
    the profile's "production". A self-host build (see Build and test) has
    neither, and `SelfHostBuild.pushDisabled` keeps it from asking for
    permission or a token: without that it prompts, then APNs refuses the
    token on every foreground.

## Scope: pull to refresh (replaces upstream's "No pull to refresh" bullet)

This replaces upstream's "No pull to refresh (Steve, for both apps)" bullet in
Scope.

- **Pull to refresh** is upstream's "none, anywhere" (Steve, d79ca825c),
  except where this fork keeps its own: every `attachRefresh` screen
  (session lists, session details and info, files, changes, document and
  todo history, the Machine screen), `PullToRefresh` on home, the sidebar
  and chats, and the in-app browser's refresh control. Don't remove
  those; a list still stays current through its feed (events, a resync
  after a gap, a read when it opens or the stream reconnects) without them.

## Record kinds: session rows (replace and add to upstream's table)

The `start` and `stop` rows replace upstream's ("invisible subagent
lifecycle"); the `progress` and `agents` rows are added after them, before the
`user-message-accepted` row.

| Record kind | Status | Evidence and normalization |
| --- | --- | --- |
| Session `start` | Current | `happy-cli/src/claude/utils/sessionProtocolMapper.ts:354`, `happy-cli/src/codex/utils/sessionProtocolMapper.ts:108`; subagent lifecycle: no row, folded into the activity bar's panel (`SubagentFold`). |
| Session `stop` | Current | `happy-cli/src/claude/utils/sessionProtocolMapper.ts:372`, `happy-cli/src/codex/utils/sessionProtocolMapper.ts:125`; subagent lifecycle: no row, folded into the activity bar's panel (`SubagentFold`). |
| Session `progress` | Current | `happy-app/sources/sync/typesRaw.ts`, `happy-app/sources/sync/storage.ts`; a running subagent's numbers: no row, folded the same way. |
| Session `agents` | Current | `happy-app/sources/sync/typesRaw.ts`; decoded, no row, and nothing folds it, as in happy-app. |

## Build and test: Self-host build (added after Variants, before Versioning)

### Self-host build

For a personal Apple team, which can't sign push or associated domains. It is
opt-in: `project.yml`, `xtool.yml` and `App/Info-*.plist` don't mention it, and
without its keys the app behaves as before (`SelfHostBuildTests`).

```sh
APPLE_TEAM_ID=ABCDE12345 APP_BUNDLE_ID_PREFIX=com.example.happy \
SELFHOST_SERVER_URL=https://happy.example.com scripts/selfhost-project.sh
open HappySelfHost.xcodeproj
```

Installing on a device is in `.agents/skills/happy-ios-ota/SKILL.md`.
`scripts/selfhost-project.sh` validates the values, derives
`.selfhost/Info-*.plist` from `App/` and generates the project from
`project.selfhost.yml`, an overlay of `project.yml`. Both outputs are
git-ignored and the team id only ever comes from the environment.

| | Normal | Self-host |
| --- | --- | --- |
| Bundle id | the RN app's | `$APP_BUNDLE_ID_PREFIX` + `.dev`, `.preview` or nothing |
| Name | Happy v2 | `$APP_DISPLAY_NAME`, default Happy |
| Entitlements | push, associated domain | none (`App/Happy-SelfHost.entitlements`) |
| Default server | `ServerConfig.defaultServerURL` | `HappyServerURL` in the plist |
| Push | on | off: `HappyPushDisabled`, no `remote-notification` mode, no Settings rows |

A self-host build resolves its server as the stored choice, then the baked URL.
The hosted server stays reachable by typing it. `isCustomServer` compares to the
baked URL, so the server form is empty on it and reset returns to it, and
`isHostedServer` is what asks "is this the hosted one?". The RN importer defaults
to the baked URL too: a build over a self-hosted RN app shares its Keychain token
but has no `server-config`, and must not send that token to the hosted server.

ATS is not relaxed. Release keeps only local networking and web content, so a
remote server must be https there; the script refuses a plain-http remote with
`APP_ENV=production`. http still works to an IP address, an undotted host or a
`.local` name. Debug and Preview allow arbitrary loads already.

xtool doesn't use any of this: `xtool.yml` stays on the dev variant.
## Adding a harness (added after Conventions, before Workstreams)

There used to be a drift test against happy-app's `harnessCatalog.ts`. Upstream
deleted happy-app, so nothing flags a harness added upstream any more: after a
pull, check upstream's harness list by hand. Gemini and OpenClaw are excluded:
an existing session shows its name, and neither can be started.

Follow OpenCode. A harness upstream doesn't have goes in files of its own, and
upstream's files get one-liners or a `case`. There is no shared harness table on
purpose: one would conflict on every pull.

1. `HappyCore/Harness/<Name>Harness.swift`: key, name, order, availability,
   defaults, resume field. `HarnessCatalog.names` gets its product name.
2. `HappyCore/Composer/<Name>Modes.swift`: a port of the Expo modes file and
   its tests, when the harness has modes of its own.
3. `HappyUI/Strings/Harnesses.swift` and the icon.
4. The hooks:
   - `MachineChoice.agentOrder` and `agentAvailable`. A niche harness counts only
     when its machine reports it (`EXPLICIT_REPORT_HARNESSES`).
   - `NewSessionDraft.Agent` and `AgentDefaults.Agent`.
   - The labels.
5. Read the daemon before trusting a spawn option. `spawnModeArgs.ts` drops modes
   for everything but Claude and Codex, so the first message must carry them.
6. Resume: `SessionDetails.resumeCommand`, `resumeAvailability` and
   `SessionQuickActions.Resume` each check the harness's id field.
7. Tool names the harness has for interactive calls go in `ChatToolDisplay`,
   `ChatToolPresentation` and `ChatRows`.

An unknown flavor must stay itself: it never borrows Claude's catalogs.
## Workstreams: Home and Composer rows (replace upstream's)

These rows replace upstream's Home row ("home header and dock") and Composer
row ("Home embeds it in the dock").

| --- | --- |
| Icons | `Sources/HappyIcons`, `scripts/generate-icons.*`, `Sources/HappyUI/Theme/IconImages.swift`, `ItemIcon`'s icon source, swapping SF Symbols for happy-app's icons in onboarding and troubleshoot, light/dark theme application |
| Home | `Screens/HomeScreens.swift`, `Screens/SessionListScreens.swift`, `Screens/HomeUltraListView.swift`, `Screens/HomeRowDrawing.swift`, `Components/NoSessionsViews.swift`, home header, the empty chat's `NewWorkPanel` and `Chat/LegacyComposeStart.swift`, new session screen, `Core/Home/` (including the new-session draft store and `SessionStarter`) |
| Composer | `Sources/HappyUI/Composer/`, `Sources/HappyLayout/Composer/`, `Sources/HappyCore/Composer/` (model, permission and effort options; `useComposerModes`). The AgentInput card is shared: the empty chat compose opens uses it, as every chat does. The phone's new session screen draws its own glass composer (`new/index.tsx` `mobileInputBox`), not the card |
