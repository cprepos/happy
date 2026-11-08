#!/bin/bash
# Recreate the happy-agent container (upstream Happy Agent on the glibc-2.39 runtime image).
# The three security-opts let bubblewrap, the agent's command sandbox, create user namespaces
# and mount /proc inside the container; Docker's default seccomp/AppArmor/masked-/proc block it
# ("user namespaces unavailable"). The old container is stopped and renamed, never removed.
set -euo pipefail
IMG=${IMG:-happy-agent-runtime:0.4.113}
TS=$(date +%Y%m%d_%H%M%S)
ENVF=$(mktemp); trap 'rm -f "$ENVF"' EXIT; chmod 600 "$ENVF"
if docker inspect happy-agent >/dev/null 2>&1; then
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' happy-agent | grep -v '^$' > "$ENVF"
  WD=$(docker inspect -f '{{.Config.WorkingDir}}' happy-agent)
  docker stop -t 30 happy-agent >/dev/null
  docker update --restart=no happy-agent >/dev/null
  docker rename happy-agent "happy-agent-old-$TS"
  echo "old container kept as happy-agent-old-$TS"
else
  WD=/home/prep/.local/share/happy-agent
  printf '%s\n' HOME=/home/prep USER=prep \
    PATH=/home/prep/.local/bin:/home/prep/.bun/bin:/home/prep/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HAPPY_HOME_DIR=/home/prep/.local/share/happy-agent/.happy HAPPY_SERVER_URL=https://happy.girthbass.duckdns.org > "$ENVF"
fi
docker run -d --name happy-agent --restart unless-stopped --network host -u 1000:1000 \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt systempaths=unconfined \
  --env-file "$ENVF" ${WD:+-w "$WD"} \
  -v /etc/ssl/certs:/etc/ssl/certs:ro -v /usr/bin/node:/usr/local/bin/node:ro \
  -v /usr/lib/node_modules:/usr/lib/node_modules:ro -v /home/prep:/home/prep \
  -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
  "$IMG" /home/prep/opt/happy-agent/happy-agent-linux-x64 run >/dev/null
sleep 3; docker exec happy-agent sh -c 'bwrap --ro-bind / / --proc /proc --dev /dev --unshare-all true && echo "sandbox OK"'
