# Self-hosted iOS build (personal Apple team)

Builds the app from this repo on your Apple Silicon Mac and installs it on your
own iPhone. It talks to `https://happy.girthbass.duckdns.org`. No App Store,
TestFlight or EAS.

`build.sh` sets `SELFHOST=1` and the related env vars that
`packages/happy-app/app.config.js` reads. In that mode the config drops push
notifications, associated domains, in-app purchase and EAS updates, because a
personal team can't sign them. The script exits if any of them still appear in
the generated entitlements.

## Prerequisites (on the Mac)

| Tool | Version | Install |
|---|---|---|
| macOS on Apple Silicon | arm64 | |
| Xcode | **16.1 minimum** (Expo SDK 55 / React Native 0.83); Xcode 26 recommended | App Store, open it once, then `sudo xcodebuild -license accept` |
| Xcode selected | full Xcode, not just Command Line Tools | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| CocoaPods | recent | `brew install cocoapods` |
| Node.js | 20.19.4+ (22 LTS recommended) | `brew install fnm && fnm install 22 && fnm use 22` (or `nvm install 22`) |
| pnpm | 10.11 (from `packageManager`) | `corepack enable` (the script activates it) |
| git | any | ships with Xcode |

Use `--simulator` only if an iOS Simulator runtime is installed (Xcode > Settings > Components).

## One-time Apple ID setup

1. **Xcode > Settings > Accounts > +  > Apple ID.** Sign in. This creates
   "*Your Name* (Personal Team)". A paid individual account works the same way.
2. **Find the team ID** (10 characters). Paid accounts: the Membership page on
   developer.apple.com. Personal Team: once a first build has created the
   signing certificate, open Keychain Access, find *Apple Development: you@…*,
   and read *Organizational Unit*. You can also open
   `packages/happy-app/ios/*.xcworkspace`, go to Signing & Capabilities, pick
   the team, and read `DEVELOPMENT_TEAM` in the build settings.
3. **iPhone:** connect it by USB, unlock it, and tap *Trust This Computer*.
   Turn on **Settings > Privacy & Security > Developer Mode** and let the
   iPhone restart. The toggle appears only after Xcode has seen the device
   once; if it's missing, open Xcode > Window > Devices and Simulators with
   the phone connected.

## First run

```bash
git clone <your fork> happy && cd happy
cp selfhost/ios/.env.ios.example selfhost/ios/.env.ios
$EDITOR selfhost/ios/.env.ios      # APPLE_TEAM_ID, APP_BUNDLE_ID_PREFIX, APP_DISPLAY_NAME
selfhost/ios/build.sh              # Release build, JS embedded, runs without the Mac
```

The script checks the tools, runs `pnpm install --frozen-lockfile`, checks the
resolved Expo config, and runs `expo prebuild -p ios --clean`. Any old
`packages/happy-app/ios` is moved to `trash/<timestamp>_ios_prebuild/`, never
deleted. It then sets `DEVELOPMENT_TEAM` and automatic signing in the Xcode
project, checks the entitlements, and runs `expo run:ios --configuration
Release --device`.

On the first launch iOS shows **"Untrusted Developer"**. Go to **Settings >
General > VPN & Device Management > Apple Development: *you* > Trust**, then
open the app again.

Options:

| Flag | Effect |
|---|---|
| `--device "Pokai's iPhone"` / UDID | Skip the device picker (or set `DEVICE=` in `.env.ios`) |
| `--debug` | Debug dev client with Metro and live reload. The phone must reach the Mac over Wi-Fi |
| `--simulator` | Simulator build. No team needed |
| `--skip-prebuild` | Reuse the existing `ios/` (fast rebuild after JS-only changes) |
| `--no-build-cache` | Clear Xcode derived data first |

## Rebuilding

- After a `git pull`, or after a dependency or native change, run `selfhost/ios/build.sh`. It does a clean prebuild.
- For JS-only changes, run `selfhost/ios/build.sh --skip-prebuild`.
- Reinstalling over the existing app keeps your login and data, as long as the bundle ID doesn't change.

## Free account limits

- **The profile expires after 7 days.** The app then stops launching ("no longer available"). Plug the phone in and rerun `selfhost/ios/build.sh --skip-prebuild`. Your data stays.
- **At most 3 sideloaded apps per device**, counting other personal-team apps. Delete one to make room.
- **At most 10 new App IDs per 7 days.** Keep `APP_BUNDLE_ID_PREFIX` and `APP_ENV` stable.
- A paid individual account ($99/yr) lasts 1 year and has none of these limits. Push notifications still stay off in self-host mode.

## Server URL in the app

The build bakes `HAPPY_PUBLIC_URL` in as the default server. To check it or
change it, open the server row on the home header or in Settings. The current
URL should be `https://happy.girthbass.duckdns.org`. After changing servers,
log out and back in. Voice uses the same server.

## Voice

Voice goes through the Happy server on port 443: the app streams audio to
`wss://happy.girthbass.duckdns.org/v1/voice/stream`, and the server joins the
LiveKit room for it (see `docs/voice-architecture.md`). LiveKit has no public
URL, so no router forwards or firewall rules are needed, on Wi-Fi or cellular.

The native app uses the same voice stream as the web app (audio on
`react-native-audio-api`), so voice on the iPhone build works with LiveKit's
public paths removed (`selfhost/cutover/CUTOVER.md`). Builds from before the
native stream joined LiveKit directly and no longer connect; rebuild with
`selfhost/ios/build.sh`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No Account for Team` / `No profiles for '<bundle id>'` | Xcode > Settings > Accounts: sign in again. Check that `APPLE_TEAM_ID` matches the team. The script passes `-allowProvisioningUpdates` through `expo run:ios`, so Xcode creates the profile on its own |
| `Failed to register bundle identifier` | The ID is taken by someone else. Change `APP_BUNDLE_ID_PREFIX` |
| `Personal development teams … do not support the Push Notifications capability` | SELFHOST mode isn't stripping push. Make sure the self-host `app.config.js` change is on your branch, then rerun without `--skip-prebuild` |
| Entitlements check fails | Same cause as the line above |
| `pod install` fails | `brew upgrade cocoapods`, `pod repo update`, then rerun. On Ruby/ffi errors, install CocoaPods with Homebrew instead of system gem |
| `node: command not found` in an Xcode build phase | The script writes `ios/.xcode.env.local` with your node path. Rerun the script from the same shell where `node -v` works |
| Debug build stuck on "Loading from Metro" or a red screen | Mac and phone must be on the same Wi-Fi. Allow incoming connections for node in the macOS firewall. Rerun with `--debug`, or use a Release build |
| "Untrusted Developer" | Settings > General > VPN & Device Management > Trust |
| "Developer Mode required" | Settings > Privacy & Security > Developer Mode, then restart |
| App stops opening after a week | Free profile expired. Rerun the build (see above) |
| Microphone does nothing or voice won't start | Settings > *App* > Microphone: on. If it was denied once, iOS won't ask again; turn it on there. Then check the voice toggle and the Voice section above |
| `xcodebuild` license or first-launch errors | `sudo xcodebuild -license accept && xcodebuild -runFirstLaunch` |
