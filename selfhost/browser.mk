# Live browser stack (auto-browser + the live bridge). Included from selfhost/Makefile via
# `-include browser.mk`; also usable directly: `make -f browser.mk browser-status`.
# See selfhost/browser/README.md.
#
#   make browser-init     generate secrets under ~/.local/share/happy-browser/secrets (600, idempotent)
#   make browser-up       start browser-node + controller + bridge (detached), loopback-only
#   make browser-down     stop and remove the containers (data and secrets kept)
#   make browser-status   container health, loopback binds, controller /healthz
#   make browser-logs     follow logs (BROWSER_SVC=controller to pick one service)
#   make browser-verify   MCP answers with the token (tools/list), refuses without it; noVNC demands a password
#   make browser-bridge-test   bridge unit tests (node:test, auto-browser mocked)
#   make browser-bridge-smoke  end-to-end against the running stack: session, link, page, frame, takeover, done
#   make browser-pod-bench     pod start times, cold and warm (test project only)
#   make browser-pod-smoke     per-chat pods end to end (bridge with BRIDGE_PODS=1)

BROWSER_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/browser
export HAPPY_BROWSER_HOME ?= $(HOME)/.local/share/happy-browser
BROWSER_SECRETS := $(HAPPY_BROWSER_HOME)/secrets
# A second project (with its own HAPPY_BROWSER_HOME and ports) can run beside the live one for tests.
export BROWSER_PROJECT ?= happy-browser
# The launcher mounts the repo at its host path, so compose needs it as a variable.
export HAPPY_BROWSER_DIR := $(BROWSER_DIR)
BROWSER_LOCAL_ENV := $(BROWSER_DIR)/.env.browser
BROWSER_COMPOSE := docker compose -p $(BROWSER_PROJECT) -f $(BROWSER_DIR)/compose.browser.yml \
	--env-file $(BROWSER_SECRETS)/browser.env $(if $(wildcard $(BROWSER_LOCAL_ENV)),--env-file $(BROWSER_LOCAL_ENV))
BROWSER_SVC ?=
BROWSER_API ?= http://127.0.0.1:8010
BROWSER_BRIDGE ?= http://127.0.0.1:6090
# Every port the stack listens on, all 127.0.0.1 (noVNC, controller, bridge, Playwright server).
# Match selfhost/browser/.env.browser if it changes a port.
BROWSER_PORTS ?= 6080|8010|6090|9223|61[0-3][0-9]|81[0-3][0-9]|93[0-3][0-9]
BROWSER_IMAGES = $(shell sed -nE 's/^x-(browser-node|controller)-image: &[a-z_]+ (.+)$$/\2/p' $(BROWSER_DIR)/compose.browser.yml) \
	$(shell sed -nE 's/^    image: (node:.+)$$/\1/p' $(BROWSER_DIR)/compose.browser.yml | sort -u)
POD_FILTER = --filter label=happy-browser.pod=1 --filter label=happy-browser.project=$(BROWSER_PROJECT)

.PHONY: browser-init browser-up browser-down browser-status browser-logs browser-verify browser-bridge-test browser-bridge-smoke \
	browser-pull browser-pods-status browser-pods-reap browser-entrypoint-check \
	browser-pod-bench browser-pod-smoke

browser-init:
	@HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" bash $(BROWSER_DIR)/scripts/browser-init.sh

browser-up: browser-init
	$(BROWSER_COMPOSE) up -d --wait

browser-down:
	$(BROWSER_COMPOSE) down

browser-status:
	@$(BROWSER_COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
	@echo
	@echo "listening on the live-browser ports $(BROWSER_PORTS) (expect 127.0.0.1 only):"
	@ss -ltnH | awk '{print $$4}' | grep -E ':($(BROWSER_PORTS))$$' | sort -u || echo "  (none)"
	@if ss -ltnH | awk '{print $$4}' | grep -E ':($(BROWSER_PORTS))$$' | grep -qvE '^127\.0\.0\.1:'; then \
		echo "WARNING: a live-browser port is bound beyond 127.0.0.1"; exit 1; fi
	@printf "controller /healthz: "; curl -fsS --max-time 5 $(BROWSER_API)/healthz || echo "unreachable"; echo
	@printf "bridge /healthz:     "; curl -fsS --max-time 5 $(BROWSER_BRIDGE)/healthz || echo "unreachable"; echo

browser-logs:
	$(BROWSER_COMPOSE) logs -f --tail=200 $(BROWSER_SVC)

browser-verify:
	@BROWSER_API="$(BROWSER_API)" HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" bash $(BROWSER_DIR)/scripts/browser-verify.sh

browser-bridge-test:
	cd $(BROWSER_DIR)/bridge && node --test test/*.test.mjs
	cd $(BROWSER_DIR)/launcher && node --test test/*.test.mjs

# Every image the stack and its pods run, by digest, so a pod never waits on a pull.
browser-pull:
	@for i in $(BROWSER_IMAGES); do docker pull -q "$$i" || exit 1; done

# Each chat's browser pod (two containers per slot), from Docker's labels.
browser-pods-status:
	@docker ps -a $(POD_FILTER) --format 'table {{.Label "happy-browser.slot"}}\t{{.Label "happy-browser.role"}}\t{{.Label "happy-browser.pod_id"}}\t{{.Status}}\t{{.Names}}' | sort -n
	@if curl -fsS --max-time 5 -H "Authorization: Bearer $$(cat $(BROWSER_SECRETS)/bridge-token)" $(BROWSER_BRIDGE)/api/pods >/dev/null 2>&1; then \
		echo; curl -fsS --max-time 5 -H "Authorization: Bearer $$(cat $(BROWSER_SECRETS)/bridge-token)" $(BROWSER_BRIDGE)/api/pods; echo; fi

# Stop and remove every pod container of this project. Slot directories are wiped by the
# launcher when the slot is next used; chats' saved logins (data/chats) are never touched.
browser-pods-reap:
	@ids=$$(docker ps -aq $(POD_FILTER)); if [ -n "$$ids" ]; then docker rm -f $$ids; else echo "no pods"; fi

# The entrypoint patch against the pinned browser-node image's own /entrypoint.sh: each
# pattern must match exactly once (scripts/browser-node-entrypoint.sh refuses to start otherwise).
browser-entrypoint-check:
	@set -e; t=$$(mktemp -d); trap 'rm -rf "$$t"' EXIT; \
	docker run --rm --network none --entrypoint cat $$(sed -nE 's/^x-browser-node-image: &[a-z_]+ (.+)$$/\1/p' $(BROWSER_DIR)/compose.browser.yml) /entrypoint.sh >"$$t/entrypoint.sh"; \
	BROWSER_NODE_ENTRYPOINT_SRC="$$t/entrypoint.sh" BROWSER_NODE_ENTRYPOINT_OUT="$$t/out.sh" BROWSER_NODE_ENTRYPOINT_DRY_RUN=1 \
		PLAYWRIGHT_SERVER_HOST=127.0.0.1 NOVNC_PORT=6100 bash $(BROWSER_DIR)/scripts/browser-node-entrypoint.sh; \
	echo "entrypoint patch: all five patterns match once; $$(diff "$$t/entrypoint.sh" "$$t/out.sh" | grep -c '^>') lines changed"

# Pod start times through the real launcher, cold and warm, p50/p95 per phase (RUNS=5, VERSION).
# Refuses while any pod of the project is up: run it against a test project.
browser-pod-bench:
	@cd $(HAPPY_BROWSER_HOME)/run && HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" RUNS="$(or $(RUNS),5)" VERSION="$(or $(VERSION),0.0.1)" \
		POD_NOVNC_BASE="$(or $(POD_NOVNC_BASE),6100)" POD_API_BASE="$(or $(POD_API_BASE),8100)" POD_PLAYWRIGHT_BASE="$(or $(POD_PLAYWRIGHT_BASE),9300)" \
		node $(BROWSER_DIR)/scripts/pod-bench.mjs

# Per-chat pods end to end through a bridge running with BRIDGE_PODS=1 (and a short
# BRIDGE_POD_IDLE_MIN, so the idle stop happens within SMOKE_IDLE_WAIT_S).
browser-pod-smoke:
	@BROWSER_BRIDGE="$(BROWSER_BRIDGE)" HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" BROWSER_PROJECT="$(BROWSER_PROJECT)" \
		node $(BROWSER_DIR)/scripts/pod-smoke.mjs

browser-bridge-smoke:
	@BROWSER_API="$(BROWSER_API)" BROWSER_BRIDGE="$(BROWSER_BRIDGE)" HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" \
		BROWSER_NODE_CONTAINER="$(BROWSER_PROJECT)-browser-node-1" node $(BROWSER_DIR)/scripts/bridge-smoke.mjs
