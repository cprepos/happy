# happy-svc: the vault and browser stacks under their own rootless Docker

The vault (compose project `happy-vault`: Vaultwarden and the filler) and the browser stack (`happy-browser`: controller, browser node, pods, bridge, launcher) run in a rootless Docker daemon owned by a dedicated system account, `happy-svc`. The operator account (`prep`), and so every agent running as prep, has no access to that daemon's socket, volumes or data. The one way in is a root-owned wrapper, `/usr/local/libexec/happy-svc-ctl`, reached through one sudoers rule, with a fixed set of verbs.

## Threat model

**What this protects.** An agent running as prep can no longer:
- read the vault's data, the filler's keys or policy, or the browser's secrets and profiles through `docker run -v`, `docker exec` or `docker cp`, or through files in prep's home;
- change what runs: the compose files, Dockerfiles and scripts come from a root-owned release (`/opt/happy-svc/releases/<sha>`), not from the working tree;
- pass arbitrary arguments or environment to Docker. The wrapper accepts only fixed verbs and checks every argument against a fixed word or a short character class. It never uses `eval`, clears the environment for each child, and logs each verb and its caller (never values) to the journal under `happy-svc-ctl`;
- enrol the filler, edit its policy, or import data. Those verbs (`admin-tty`, `import`) are outside the password-free rule and need prep's own sudo password.

**What it does not protect against:**
- root, the kernel, or anyone with prep's sudo password;
- prep's membership of `docker` (the rootful daemon) or `lxd`. Either one is root in effect, so as long as prep keeps it, an agent can still reach any file. `setup-root.sh` warns about it; cutover step 6 removes it.
- sudo's credential cache. After you type your password for `import` or `admin-tty`, an agent in the same terminal session can use sudo until the timestamp expires. Run `sudo -k` afterwards, or set `timestamp_timeout=0`.
- a compromise of a container. Container root is `happy-svc` on the host, so a container escape reaches all of happy-svc's data, though nothing of prep's or root's.
- the tokens prep holds by design: the bridge and vault client tokens, and the controller `api-token`, which the host bridge stdio MCP needs. Whoever holds them can do what those clients can do.
- the code you approve. A deploy installs exactly the commit you name. Agents can commit and push, so review the sha before you run the root command.

## The pieces

| Path | Owner, mode | What |
|---|---|---|
| `/usr/local/libexec/happy-svc-ctl` | root 0755 | the wrapper (from the release) |
| `/etc/sudoers.d/happy-svc` | root 0440 | prep may run the wrapper as happy-svc, password-free verbs only |
| `/opt/happy-svc/releases/<sha>`, `current` | root 0755 | `selfhost/svc`, `selfhost/vault`, `browser-stack` of one commit |
| `/opt/happy-svc/src.git` | root 0700 | hash-checked objects of deployed commits |
| `/etc/happy-svc/{vault,browser}.env` | root 0644 | allowlisted settings (`make svc-settings`, `--settings`) |
| `/var/lib/happy-svc` | happy-svc 0700 | home: Docker data, `data/browser` (the browser home), `backups/`, `imported/` |
| `/var/lib/happy-svc-drop/in` | happy-svc:prep 3770 | where prep drops tarballs for `import` |
| `~happy-svc/.config/systemd/user/` | happy-svc | `docker.service` (rootless dockerd), `happy-svc-ports.service`, `happy-svc-backup.{service,timer}` |

The daemon runs slirp4netns, sandboxed and seccomp-filtered, with the builtin port driver and host loopback disabled, so no container can reach the host's 127.0.0.1. All of happy-svc's containers share rootlesskit's network namespace: `network_mode: host` means that namespace, not the host's. The services bind 127.0.0.1 inside it, and the filler reaches the controller and Vaultwarden there. The wrapper publishes the ports in `ports.list` on the host's 127.0.0.1 only, through rootlesskit's API. Every run of `ports`, `up` and `happy-svc-ports.service` (each time the daemon starts) also removes any published port bound to anything but 127.0.0.1.

## Verbs

`make` target, wrapper verb and whether sudo asks for a password:

| make | wrapper | password |
|---|---|---|
| `svc-up [P=vault\|browser]` | `up [P]`: compose up --build --wait (vault, then browser), then publish ports | no |
| `svc-down [P=..]` | `down [P]`: browser, then vault; volumes kept | no |
| `svc-restart P=.. [S=..]` | `restart P [svc]`: the service must be in that project | no |
| `svc-status` | `status`: daemon, containers, ports loopback-only check | no |
| `svc-logs P=.. S=.. [F=1]` | `logs P svc [follow]`: last 200 lines | no |
| (systemd) | `ports`: publish `ports.list` on 127.0.0.1 | no |
| `svc-init` | `init`: vault-init.sh, browser-init.sh, the filler image and its empty layout | no |
| `svc-admin A=".."` | `admin init\|items\|tokens-missing\|controller-token-take\|outbox-clear\|check-policy\|policy-upgrade\|seed-policy [CLIENT=x]\|token-issue NAME=bridge-client\|vault-client [ROTATE=1]` | no |
| `svc-tokens` | `tokens-export` (checked tokens on stdout; make writes 0600 files) and `controller-token` | no |
| `svc-backup` (and nightly) | `backup` | no |
| `svc-enroll`, `svc-policy-edit` | `admin-tty enroll\|policy-edit` (needs your terminal) | **yes** |
| `svc-migrate` (prints them) | `import <volume>` from the drop directory, into a new, empty volume | **yes** |
| `svc-setup-print`, `svc-deploy` | print the root commands; they run nothing | n/a |
| `svc-test` | the tests below; no root, no Docker | n/a |

## What the compose files must provide (V2.1)

The wrapper runs the compose files of the release unchanged, adding only `compose.rootless.vault.yml` and `compose.rootless.browser.yml` from this directory. It sets this environment for every compose call: `DOCKER_HOST` and `HAPPY_DOCKER_SOCKET=/run/user/<uid>/docker.sock`, `HAPPY_BROWSER_HOME=/var/lib/happy-svc/data/browser`, `HAPPY_BROWSER_DIR=<release>/browser-stack/browser`, `BROWSER_PROJECT=happy-browser`, `BRIDGE_UID=0`, `BRIDGE_GID=0`, and empty `BRIDGE_LAN_*`. In return, the compose files must:

1. **Name the volumes explicitly.** They should be external volumes with `name:` set, matching `volumes.list`: `happy-vault-data`, `happy-vault-config`, `happy-vault-backups` and `happy-filler`. vault-init.sh creates them. Everything else lives under `HAPPY_BROWSER_HOME`.
2. **Take the Docker socket from a variable.** The launcher must mount `${HAPPY_DOCKER_SOCKET:-/var/run/docker.sock}:/var/run/docker.sock`, not a fixed `/var/run/docker.sock`. Under happy-svc the fixed path is the rootful daemon, which the launcher must not reach. This is the one change still open in `browser-stack/browser/compose.browser.yml`. The rootless override does not patch it, because an override can only add a socket, not move one safely.
3. **Use no host paths outside the release and `HAPPY_BROWSER_HOME`.** In particular, nothing under `/home/prep`.
4. **Bind 127.0.0.1 only.** On the host network every listener binds 127.0.0.1, and no `ports:` entries remain. The vault override resets Vaultwarden's `ports:` and puts it on the host network, so the wrapper's `ports.list` is the one publishing path. Any other published port that is not on 127.0.0.1 is removed.
5. **Account for uid mapping.** Container uid 0 is happy-svc on the host. Every other container uid maps into happy-svc's subuid range. A file a container must read has to belong to its container uid. vault-init.sh and browser-init.sh set this up from containers. `import` keeps the numeric owners and maps prep's uid and gid 1000 to 0 in the browser home.
6. **Keep the filler handoff.** The filler accepts an `inbox/controller-token` only if it belongs to another uid. The wrapper writes it as container root, mode 0640, group 1990 from the setgid `inbox/`.

## Setup and cutover

1. Commit and push the stack as usual, and review the commit.
2. As prep, run `make svc-settings`, then check `selfhost/svc/.settings/*.env`. Only the allowlisted keys go in.
3. Run `make svc-setup-print`. It prints the root command for HEAD:

   ```
   sudo bash /home/prep/happy/selfhost/svc/setup-root.sh --commit <sha> --settings /home/prep/happy/selfhost/svc/.settings [--install-packages]
   ```

   Run it yourself, first with `--dry-run`. It prints every step and is idempotent. It:
   - checks the packages (`uidmap` is not installed yet on prep-ml);
   - creates the `happy-svc` account and its subuid/subgid range;
   - deploys the release, then refuses to go on if the `setup-root.sh` or `deploy-root.sh` you ran differs from the release's copy;
   - installs the wrapper and the drop directory;
   - enables linger and the rootless dockerd;
   - installs the sudoers rule after `visudo -cf`;
   - checks that prep cannot read `~happy-svc` or the socket, and cannot run anything else as happy-svc without a password.
4. Move the data:
   - run `make stack-down` (your Docker);
   - run `make svc-migrate`, which tars each volume and the browser home into the drop;
   - run each printed `sudo -u happy-svc /usr/local/libexec/happy-svc-ctl import <volume>` (your password), then `sudo -k`.

   For a fresh install, run `make svc-init` instead.
5. Run `make svc-up`, `make svc-tokens` and `make svc-status`. If the filler is not yet enrolled, run `make svc-enroll`. Check the vault and the bridge from the host on their usual 127.0.0.1 ports.
6. Once it is healthy, remove prep from the `docker` and `lxd` groups (`sudo gpasswd -d prep docker`, the same for `lxd`, then log in again). Until then the isolation is only nominal. Leave prep's old volumes and `~/.local/share/happy-browser` until you are sure. They are your rollback.

Later releases: `make svc-deploy` prints `sudo bash .../deploy-root.sh <sha> [--settings ...]`, then run `make svc-up`. Old releases are kept, so going back is deploying the older sha (switching is instant).

## Rollback

- **Services only:** `sudo bash selfhost/svc/teardown-root.sh [--dry-run]`. It moves the sudoers file and the wrapper to `/var/lib/happy-svc-old/<ts>/` with a README, stops and disables the user units and turns off linger. The account, data, backups, releases and settings stay. `--move-data-aside` renames `~happy-svc/data`; it deletes nothing.
- **Back to your Docker:** if prep's own volumes and browser home were left in place (step 6), run `make stack-up` as before. If the data changed under happy-svc since then, first run `make svc-backup`, then restore from the newest `~happy-svc/backups/<ts>/` as root, for example into new volumes on your Docker with `tar -xpf --numeric-owner`. In the browser home, map uid 0 back to 1000.
- Re-running `setup-root.sh` brings everything back from the current release.

## Backups

`happy-svc-backup.timer` runs `backup` nightly (03:30, catching up after downtime). `make svc-backup` runs one now. Each run writes `~happy-svc/backups/<ts>/<volume>.tar.gz` for every entry in `volumes.list`, plus `SHA256SUMS`. It also copies the run to each mirror directory listed in root's `/etc/happy-svc/backup-mirrors`, one absolute path per line; each mirror must be happy-svc's and mode 0700. Nothing is ever pruned: watch the disk and move old runs aside yourself. The tarballs contain the vault's data and the filler's keys, so they are as sensitive as the volumes.

## Tests

`make svc-test` needs neither root nor Docker. It runs:
- shellcheck on every script;
- `visudo -cf` on the sudoers template and on the rendered file, and checks that it is runas happy-svc only, with no password-free `admin-tty` or `import`;
- the wrapper in its test mode against a fake docker and curl: the refusals, the argument validation, the commands each verb runs, the cleared environment, loopback-only ports, the tokens-export checks, import's no-overwrite rule and the journal content;
- the root scripts' refusals without root.

Test mode exists only when the wrapper runs from somewhere other than its installed path, with `HAPPY_SVC_CTL_TEST=1` and not under sudo. The installed copy ignores every `HAPPY_SVC_CTL_*` variable.

## Open risks

- **Not run live.** Nothing here has run on prep-ml yet. `uidmap` (newuidmap) is missing, so a rootless daemon could not be started for a test. The rootlesskit port API calls (`/v1/ports`) follow rootlesskit 2.3's API but are untested against it.
- **cgroup v1.** prep-ml uses cgroup v1, so the rootless daemon cannot apply `pids_limit`, memory or cpu limits; the compose files' limits are ignored.
- **Chromium's sandbox.** It needs nested user namespaces inside the rootless one (`kernel.unprivileged_userns_clone=1`, and a seccomp profile that allows `clone`/`unshare`). AppArmor profiles are not applied rootless. Verify the browser node and the pods start with the sandbox on.
- **The bridge's LAN listener is off.** The namespace has no LAN address, so phone access over the LAN needs another path, such as the gateway.
- **"localhost" in Chromium is the namespace,** not the host. Pages served on the host's 127.0.0.1 are not reachable from the browser any more.
- **The bridge runs as container root,** which is happy-svc on the host, so it can read all of happy-svc's data, as it could read prep's before.
- **The root step runs a file from the working tree.** `setup-root.sh` compares itself and `deploy-root.sh` with the release's copies, but a modified script could skip that check. Run it right after reviewing, or from a copy you made.
- **Per-deploy sudo.** Each deploy needs your sudo by design. Agents can prepare a commit but not roll it out.
