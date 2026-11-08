# Runtime image for upstream Happy Agent (glibc >= 2.39 needed by its bundled monty addon;
# the host is glibc 2.35). The agent binary itself is bind-mounted from /home/prep/opt/happy-agent.
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates bubblewrap socat git ripgrep curl python3 procps less openssh-client \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex
