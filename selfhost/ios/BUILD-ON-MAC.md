# Build on the Mac from the Linux box

`build-on-mac.sh` runs on the Linux box. It copies this checkout to the Mac
(`prep-air`, `~/happy-build`), builds a Release app there signed with your
personal Apple team, and installs it on your iPhone with `devicectl`. The app
talks to `https://happy.girthbass.duckdns.org`, which comes from `PUBLIC_URL`
in `selfhost/.env`.

```bash
selfhost/ios/build-on-mac.sh                 # sync + pnpm install, build, install
selfhost/ios/build-on-mac.sh --sync-only     # rsync + pnpm install only
selfhost/ios/build-on-mac.sh --build-only    # prebuild + xcodebuild on the Mac
selfhost/ios/build-on-mac.sh --install-only  # reinstall the last build
selfhost/ios/build-on-mac.sh --skip-prebuild # keep the Mac's ios/ (JS-only changes)
APPLE_TEAM_ID=ABCDE12345 selfhost/ios/build-on-mac.sh   # team ID without the config file
```

`-h` lists every option. Each run is safe to repeat.

- **Sync.** Copies the working tree, uncommitted changes included. It skips
  `.git`, `node_modules`, the generated `ios/` and `android/` folders,
  `trash/`, `.claude/`, every `.env*` file, key and certificate files, and
  everything under `selfhost/` except `selfhost/ios/`. Files on the Mac that
  the sync deletes or replaces are moved to `~/happy-build-trash/<ts>_rsync_replaced/`.
- **Mac tools.** The Mac stages use Homebrew `node@24` and the pnpm version
  pinned by `packageManager`, which corepack provides.
- **Prebuild.** The previous `packages/happy-app/ios` is moved to
  `~/happy-build-trash/<ts>_ios_prebuild/` before `expo prebuild --clean`.
  These folders hold generated files, so you can delete them when disk gets
  tight.

## Mac config

Create `~/happy-build/selfhost/ios/.env.ios` on the Mac. It is git-ignored,
and the sync never copies or deletes it.

```
APPLE_TEAM_ID=ABCDE12345
APP_BUNDLE_ID_PREFIX=org.duckdns.girthbass   # letters/digits only; the bundle id gets ".preview" added
APP_DISPLAY_NAME=Happy
APP_ENV=preview
DEVICE=                                      # optional: iPhone name or UDID
```

Variables you set on the Linux command line take priority over this file.

## One-time manual steps

1. **Install Xcode** from the App Store and open it once, so it installs its
   components.
2. **Run these sudo commands** in Terminal on the Mac:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   xcodebuild -runFirstLaunch
   ```
3. **Add your Apple ID** in Xcode > Settings > Accounts > + > Apple ID. This
   creates "Your Name (Personal Team)".
4. **Find your Team ID** (10 characters). In Xcode > Settings > Accounts,
   select the Apple ID; the team row shows the ID in recent Xcode versions.
   Other places to find it:
   - Paid accounts: developer.apple.com > Account > Membership details.
   - Personal Team: after the first signing attempt, open Keychain Access,
     find the certificate *Apple Development: you@...*, and read
     *Organizational Unit*.
   - From a Mac terminal, once that certificate exists:
     `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`
     prints the ID as `OU=`.
5. **Connect the iPhone by USB.** Unlock it and tap *Trust This Computer*.
   Open Xcode > Window > Devices and Simulators once so the phone pairs. Then
   turn on **Settings > Privacy & Security > Developer Mode**; the phone
   restarts. After this first pairing, installs also work over Wi-Fi when the
   phone is unlocked and on the same network.
6. **Let codesign use the keychain over ssh.** Do this once, from Terminal on
   the Mac: run `bash ~/happy-build/selfhost/ios/build-on-mac.sh --build-only`
   and click *Always Allow* when codesign asks for the key. Before later
   ssh-driven builds, run
   `security unlock-keychain ~/Library/Keychains/login.keychain-db` if the
   build fails with `errSecInternalComponent`.
7. **Trust the developer profile** after the first install. On the iPhone, go
   to Settings > General > VPN & Device Management > Apple Development: you >
   Trust.

## Free Apple ID limits

- The provisioning profile expires after 7 days. Rerun the script to refresh
  it; your data is kept.
- At most 3 sideloaded apps can be on one device.
- At most 10 new app IDs can be registered per week. Keep
  `APP_BUNDLE_ID_PREFIX` and `APP_ENV` stable.

`build.sh` in this folder is the older script that runs only on the Mac (it
uses `expo run:ios`). Its README also covers troubleshooting.
