---
name: happy-ios-ota
description: >
  Build the native Happy iOS app (packages/happy-ios, bundle org.girthbass.native, "Happy v2
  (preview)") from a commit, sign it, and either install it on a device over USB/LAN with
  devicectl or publish it to the over-the-air install page so the iPhone/iPad can install it
  from Safari anywhere. Use when the user asks to install a happy-ios build on the iPhone or
  iPad, wants an OTA / install link, or the device isn't reachable directly (user away from home).
  Not for the Expo app (packages/happy-app): that goes through the repo's release skill (EAS).
---

# happy-ios OTA install

Proven end to end on 2026-11-02, commit `41e3c1055`, build TS `20261102_200448`.

## What this is (and isn't)

- The native app is **development-signed** on prep-air (team `74YS5XP5GW`; the profile expires
  2027-10-27). Over-the-air install only works on devices that are in that profile (the user's iPhone and iPad;
  get their UDIDs from `xcrun devicectl list devices` on prep-air). A new device needs adding to
  the profile and a re-sign.
- It is not an EAS/Expo release, so `.agents/skills/release` doesn't cover it. That skill is for
  `packages/happy-app`.
- **Publishing replaces what the OTA page serves, which counts as a deploy.** The permission
  classifier blocks the publish step for agents ("Production Deploy"). Get the user's explicit
  OK in the current conversation, then run the publish step in the main session. Don't
  route around a block.

## Hosting (already set up — no Caddy change needed)

- `/home/prep/caddy/Caddyfile`, site `happy.girthbass.duckdns.org`, has a no-auth
  `handle_path /ota/*` → `root /home/prep/happy-ota`. It sets plist→`text/xml`,
  ipa→`application/octet-stream`, `no-store`, `noindex`, and hides `.current`.
  The Caddyfile contains plaintext API tokens: never print it whole, and never repeat those tokens.
- The install folder is the single unguessable hash directory under `/home/prep/happy-ota/`. That path
  is the only protection on a no-login download. Treat it as a secret: never commit it (this repo
  is public), and never post it anywhere public. Look it up on the server:
  `D=$(find /home/prep/happy-ota -mindepth 1 -maxdepth 1 -type d); H=$(basename "$D")`
  - `manifest.plist` points at `https://happy.girthbass.duckdns.org/ota/<hash>/Happy.ipa`,
    bundle-identifier `org.girthbass.native`, title "Happy v2 (preview)". It doesn't need editing
    per build.
  - `index.html` has the Install button (`itms-services://?action=download-manifest&url=<urlencoded manifest URL>`).
  - `Happy.ipa` is the build being served. Old builds are kept as `Happy.ipa.bak-YYYYMMDD[a-z]`.
  - Don't touch `/home/prep/happy-ota/.current` (mode 600, purpose unknown).
- **Link to give the user:**
  `https://happy.girthbass.duckdns.org/ota/$H/index.html`.
  They open it in **Safari** on the device and tap Install. It replaces the installed copy, and the data is kept.

## Steps

Hosts: prep-pro compiles (see the prep-pro skill), prep-air signs and runs devicectl (see the
prep-air skill). The source comes from the deploy checkout `/home/prep/happy` (`git pull -q --ff-only fork main` first if you're
building latest main). Use `ssh -o BatchMode=yes`.

### 1. Stage source on prep-pro
```bash
C=$(git -C /home/prep/happy rev-parse <commit>)
TS=$(ssh -o BatchMode=yes prep-pro 'date +%Y%m%d_%H%M%S')
ssh prep-pro "mkdir -p ~/happy-phone-build/$TS/{src,logs} && echo $C > ~/happy-phone-build/$TS/SOURCE_COMMIT"
sed "s/__TS__/$TS/g" /home/prep/happy/.agents/skills/happy-ios-ota/prep.sh.template | ssh prep-pro "cat > ~/happy-phone-build/$TS/prep.sh && chmod +x ~/happy-phone-build/$TS/prep.sh"
git -C /home/prep/happy archive $C packages/happy-ios | ssh prep-pro "tar -x -C ~/happy-phone-build/$TS/src"
```
`prep.sh` patches `project.yml`: it adds DEVELOPMENT_TEAM and sets the Preview bundle ID to `org.girthbass.native`.
It blanks the entitlements, runs xcodegen, seeds SPM packages from
`~/happy-phone-build/20261101_221505/dd/SourcePackages` (if that folder is gone, delete that line and
let SPM resolve), and builds the `Preview` configuration with `CODE_SIGNING_ALLOWED=NO`.
If a project.yml assert fails, the project layout changed. Fix the template; don't skip the step.

### 2. Compile (prep-pro, about 5 min)
```bash
ssh prep-pro "cd ~/happy-phone-build/$TS && nohup /bin/zsh ./prep.sh > logs/prep.out 2>&1 < /dev/null &"
# poll: grep "COMPILE EXIT" ~/happy-phone-build/$TS/logs/compile.log  → want "COMPILE EXIT 0"
```

### 3. Copy unsigned app to prep-air
```bash
ssh prep-air "mkdir -p ~/happy-phone-build/$TS/{unsigned,logs} && echo $C > ~/happy-phone-build/$TS/SOURCE_COMMIT"
sed "s/__TS__/$TS/g" /home/prep/happy/.agents/skills/happy-ios-ota/sign.sh.template | ssh prep-air "cat > ~/happy-phone-build/$TS/sign.sh && chmod +x ~/happy-phone-build/$TS/sign.sh"
ssh prep-pro "cd ~/happy-phone-build/$TS/dd/Build/Products/Preview-iphoneos && tar -cf - Happy.app" \
  | ssh prep-air "tar -xf - -C ~/happy-phone-build/$TS/unsigned"
```
Check for new `.appex` or entitlements first (`find Happy.app -maxdepth 2 -name '*.appex'`).
sign.sh only knows the dylibs and frameworks plus the base entitlements. A new capability means a new profile.

### 4. Sign (prep-air, from the GUI session)
Codesigning over plain ssh fails with `errSecInternalComponent`, so run it through Terminal:
```bash
ssh prep-air "osascript -e 'tell application \"Terminal\" to do script \"/bin/bash ~/happy-phone-build/$TS/sign.sh\"'"
# poll: grep "SIGN EXIT" ~/happy-phone-build/$TS/logs/sign.log  → want "SIGN EXIT 0"
```
sign.sh refuses to run if `signed/` exists (exit 91). Use a new TS rather than deleting it.

### 5a. Direct install (device on the LAN/USB, unlocked)
```bash
ssh prep-air "xcrun devicectl list devices"   # "unavailable" = not reachable → use 5b
ssh prep-air "xcrun devicectl device install app --device <UDID> ~/happy-phone-build/$TS/signed/Happy.app && \
              xcrun devicectl device process launch --device <UDID> org.girthbass.native"
```

### 5b. Package the .ipa (this box)
```bash
W=/home/prep/happy-phone-ota-pkg/$TS; [ -e $W ] && exit 1; mkdir -p $W/Payload
rsync -a prep-air:happy-phone-build/$TS/signed/Happy.app $W/Payload/
cd $W && zip -qry Happy.ipa Payload && sha256sum Happy.ipa
unzip -l Happy.ipa | grep -E 'Payload/Happy.app/(embedded.mobileprovision|_CodeSignature/CodeResources)$'  # both must appear
```

### 6. Publish (needs the user's OK; run it in the main session)
```bash
D=$(find /home/prep/happy-ota -mindepth 1 -maxdepth 1 -type d)
B=$D/Happy.ipa.bak-$(date +%Y%m%d)a   # bump the letter if it exists — never overwrite a .bak
[ -e $B ] && { echo "pick another suffix"; exit 1; }
mv $D/Happy.ipa $B && install -m 644 $W/Happy.ipa $D/Happy.ipa
```

### 7. Verify
```bash
U=https://happy.girthbass.duckdns.org/ota/$(basename "$D")
curl -sI $U/Happy.ipa | grep -iE '^HTTP|content-length'   # 200, size matches
curl -s  $U/Happy.ipa | sha256sum                           # matches step 5b
curl -sI $U/manifest.plist | grep -iE '^HTTP|content-type'  # 200, text/xml
```
Then give the user the `index.html` link above. Tell them which commit it is, and that the previous ipa
was kept as `.bak-*`.

## Rolling back
Swap the files back with `mv`: move the current `Happy.ipa` to a new `.bak-*` name, then rename the old `.bak-*` to `Happy.ipa`.
Don't delete anything. Pruning old `.bak-*` files goes through the trash-folder rule and needs the user's approval.
