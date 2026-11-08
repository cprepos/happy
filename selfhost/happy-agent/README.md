# Happy Agent container (prep-ml)

The upstream Happy Agent daemon on prep-ml runs in the `happy-agent` Docker
container. Its bundled native addon needs glibc >= 2.38 and the host has 2.35,
so the binary (`/home/prep/opt/happy-agent/happy-agent-linux-x64`) is
bind-mounted into an Ubuntu 24.04 runtime image.

- `Dockerfile`: the runtime image (`happy-agent-runtime:<agent version>`).
  Build it with `docker build -t happy-agent-runtime:0.4.113 .` from this folder.
- `run-container.sh`: recreates the container. It copies the environment
  from the running container, then stops it and renames it to
  `happy-agent-old-<timestamp>`; nothing is removed. It ends with a
  bubblewrap check that prints `sandbox OK`.

The container runs with seccomp, AppArmor and the masked /proc paths turned
off (`--security-opt seccomp=unconfined apparmor=unconfined
systempaths=unconfined`). Without them bubblewrap, the agent's command
sandbox, fails with "user namespaces unavailable".

The live copies are in `/home/prep/opt/happy-agent/` (`run-container.sh`,
`image/Dockerfile`); keep them in step with these.

Reload the agent's config without recreating the container:

    docker exec -u 1000 -e HAPPY_HOME_DIR=/home/prep/.local/share/happy-agent/.happy \
      happy-agent /home/prep/opt/happy-agent/happy-agent-linux-x64 reload
