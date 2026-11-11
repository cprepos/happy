# Live browser stack (auto-browser + the live bridge). Included from browser-stack/Makefile and
# selfhost/Makefile; also usable directly: `make -f browser.mk browser-status`.
# See browser-stack/browser/README.md.
#
#   make browser-init     generate secrets under ~/.local/share/happy-browser/secrets (600, idempotent)
#   make browser-up       start browser-node + controller + bridge (detached), loopback-only
#   make browser-down     stop and remove the containers (data and secrets kept)
#   make browser-status   container health, loopback binds, controller /healthz
#   make browser-logs     follow logs (BROWSER_SVC=controller to pick one service)
#   make browser-verify   MCP answers with the token (tools/list), refuses without it; noVNC demands a password
#   make browser-bridge-test   bridge unit tests (node:test, auto-browser mocked)
#   make browser-controller-patch-test  the controller patch (controller-patch/) against the pinned image
#   make browser-bridge-smoke  end-to-end against the running stack: session, link, page, frame, takeover, done
#   make browser-bridge-restart  restart only the bridge container; lists the held links it releases on the way down
#   make browser-pod-bench     pod start times, cold and warm (test project only)
#   make browser-pod-smoke     per-chat pods end to end (bridge with BRIDGE_PODS=1)
#   make browser-pods-reap     remove pods no chat is using (asks first; DRY_RUN=1 lists only, FORCE=1 removes all)

BROWSER_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/browser
# BROWSER_STACK_HOME is the name to use; HAPPY_BROWSER_HOME is still read, and is exported
# with the same value because compose.browser.yml and the scripts use it.
BROWSER_STACK_HOME ?= $(or $(HAPPY_BROWSER_HOME),$(HOME)/.local/share/happy-browser)
export BROWSER_STACK_HOME
export HAPPY_BROWSER_HOME := $(BROWSER_STACK_HOME)
BROWSER_SECRETS := $(HAPPY_BROWSER_HOME)/secrets
# A second project (with its own HAPPY_BROWSER_HOME and ports) can run beside the live one for tests.
export BROWSER_PROJECT ?= happy-browser
# The launcher mounts the repo at its host path, so compose needs it as a variable.
export HAPPY_BROWSER_DIR := $(BROWSER_DIR)
# The Docker daemon's socket, which only the docker-proxy container mounts, and its group, which
# that container is given (0 under a rootless daemon, whose socket belongs to container root).
export HAPPY_DOCKER_SOCKET ?= /var/run/docker.sock
export DOCKER_SOCKET_GID ?= $(shell stat -c %g $(HAPPY_DOCKER_SOCKET) 2>/dev/null)
BROWSER_LOCAL_ENV := $(BROWSER_DIR)/.env.browser
BROWSER_COMPOSE := docker compose -p $(BROWSER_PROJECT) -f $(BROWSER_DIR)/compose.browser.yml \
	--env-file $(BROWSER_SECRETS)/browser.env $(if $(wildcard $(BROWSER_LOCAL_ENV)),--env-file $(BROWSER_LOCAL_ENV))
comma := ,
BROWSER_SVC ?=
BROWSER_API ?= http://127.0.0.1:8010
BROWSER_BRIDGE ?= http://127.0.0.1:6090
# Every port the stack listens on, all 127.0.0.1 (noVNC, controller, bridge, Playwright server).
# Match browser-stack/browser/.env.browser if it changes a port.
BROWSER_PORTS ?= 6080|8010|6090|9223|61[0-3][0-9]|81[0-3][0-9]|93[0-3][0-9]
# The bridge's opt-in LAN listener (BRIDGE_LAN_BIND in .env.browser): the one bind allowed beyond
# 127.0.0.1, and only on the bridge's port.
BRIDGE_LAN_BIND ?= $(shell sed -nE 's/^BRIDGE_LAN_BIND=([0-9.]+)[[:space:]]*$$/\1/p' $(BROWSER_LOCAL_ENV) 2>/dev/null | tail -1)
BRIDGE_LAN_PORT ?= $(or $(shell sed -nE 's/^BRIDGE_PORT=([0-9]+)[[:space:]]*$$/\1/p' $(BROWSER_LOCAL_ENV) 2>/dev/null | tail -1),6090)
# The browser's window (BROWSER_KIOSK in .env.browser): 0, the default, a normal Chromium window
# maximized to the screen, with its tab strip and address bar; 1, the kiosk (one page, no browser
# UI). The page's height follows: the whole screen in kiosk mode, the screen less Chromium's tab
# strip and toolbar (CHROME_UI_HEIGHT, measured on the pinned image) otherwise. Exported, so
# compose (and through it the launcher, for every pod) uses these over .env.browser's.
BROWSER_KIOSK ?= $(or $(shell sed -nE 's/^BROWSER_KIOSK=([^[:space:]]*)[[:space:]]*$$/\1/p' $(BROWSER_LOCAL_ENV) 2>/dev/null | tail -1),0)
BROWSER_HEIGHT ?= $(or $(shell sed -nE 's/^BROWSER_HEIGHT=([0-9]+)[[:space:]]*$$/\1/p' $(BROWSER_LOCAL_ENV) 2>/dev/null | tail -1),1200)
CHROME_UI_HEIGHT := 87
BROWSER_VIEWPORT_HEIGHT ?= $(if $(filter 1,$(BROWSER_KIOSK)),$(BROWSER_HEIGHT),$(shell expr $(BROWSER_HEIGHT) - $(CHROME_UI_HEIGHT)))
export BROWSER_KIOSK BROWSER_HEIGHT BROWSER_VIEWPORT_HEIGHT
# The zone of the date/time bar stamped across the top of every screenshot (an IANA name): the
# host's own (/etc/timezone), else America/Toronto. The controller refuses to start on a bad one.
EVIDENCE_TZ ?= $(or $(shell cat /etc/timezone 2>/dev/null | head -1 | tr -d '[:space:]'),America/Toronto)
export EVIDENCE_TZ
BROWSER_BIND_OK = ^127\.0\.0\.1:$(if $(BRIDGE_LAN_BIND),|^$(subst .,\.,$(BRIDGE_LAN_BIND)):$(BRIDGE_LAN_PORT)$$)
BROWSER_IMAGES = $(shell sed -nE 's/^x-(browser-node|controller)-image: &[a-z_]+ (.+)$$/\2/p' $(BROWSER_DIR)/compose.browser.yml) \
	$(shell sed -nE 's/^    image: (node:.+)$$/\1/p' $(BROWSER_DIR)/compose.browser.yml | sort -u)
POD_FILTER = --filter label=happy-browser.pod=1 --filter label=happy-browser.project=$(BROWSER_PROJECT)

.PHONY: browser-init browser-up browser-down browser-status browser-logs browser-verify browser-bridge-test browser-bridge-smoke browser-bridge-restart \
	browser-pull browser-pods-status browser-pods-reap browser-entrypoint-check \
	browser-pod-bench browser-pod-smoke browser-controller-patch-test

browser-init:
	@HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" bash $(BROWSER_DIR)/scripts/browser-init.sh

browser-up: browser-init
	$(BROWSER_COMPOSE) up -d --wait

browser-down:
	$(BROWSER_COMPOSE) down

browser-status:
	@$(BROWSER_COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
	@echo
	@echo "listening on the live-browser ports $(BROWSER_PORTS) (expect 127.0.0.1 only$(if $(BRIDGE_LAN_BIND),$(comma) plus $(BRIDGE_LAN_BIND):$(BRIDGE_LAN_PORT))):"
	@ss -ltnH | awk '{print $$4}' | grep -E ':($(BROWSER_PORTS))$$' | sort -u || echo "  (none)"
	@if ss -ltnH | awk '{print $$4}' | grep -E ':($(BROWSER_PORTS))$$' | grep -qvE '$(BROWSER_BIND_OK)'; then \
		echo "WARNING: a live-browser port is bound beyond 127.0.0.1$(if $(BRIDGE_LAN_BIND), and $(BRIDGE_LAN_BIND):$(BRIDGE_LAN_PORT))"; exit 1; fi
	@$(if $(BRIDGE_LAN_BIND),printf "bridge LAN /healthz: "; curl -fsS --max-time 5 -o /dev/null -w '%{http_code} from this host (not in the allowlist: expect 000)\n' http://$(BRIDGE_LAN_BIND):$(BRIDGE_LAN_PORT)/healthz || echo,true)
	@printf "controller /healthz: "; curl -fsS --max-time 5 $(BROWSER_API)/healthz || echo "unreachable"; echo
	@printf "bridge /healthz:     "; curl -fsS --max-time 5 $(BROWSER_BRIDGE)/healthz || echo "unreachable"; echo

browser-logs:
	$(BROWSER_COMPOSE) logs -f --tail=200 $(BROWSER_SVC)

browser-verify:
	@BROWSER_API="$(BROWSER_API)" HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" bash $(BROWSER_DIR)/scripts/browser-verify.sh

browser-bridge-test:
	cd $(BROWSER_DIR)/bridge && node --test test/*.test.mjs
	cd $(BROWSER_DIR)/launcher && node --test test/*.test.mjs
	cd $(BROWSER_DIR)/docker-proxy && node --test test/*.test.mjs
	cd $(BROWSER_DIR)/kiosk && node --test test/*.test.mjs

# The controller patch (controller-patch/: the live frames and the evidence stamp) in a throwaway container of the
# pinned controller image, no network: its pin check against the image's files, then its tests.
CONTROLLER_IMAGE = $(shell sed -nE 's/^x-controller-image: &[a-z_]+ (.+)$$/\1/p' $(BROWSER_DIR)/compose.browser.yml)
browser-controller-patch-test:
	docker run --rm --name happy-controller-patch-test-$$$$ --network none --entrypoint python \
		-e PYTHONPATH=/happy/controller-patch -e HAPPY_LIVE_FRAMES_NO_AUTOLOAD=1 -w /app \
		-v $(BROWSER_DIR)/controller-patch:/happy/controller-patch:ro $(CONTROLLER_IMAGE) \
		-m unittest -v test_happy_live_frames test_happy_evidence_stamp

# Every image the stack and its pods run, by digest, so a pod never waits on a pull.
browser-pull:
	@for i in $(BROWSER_IMAGES); do docker pull -q "$$i" || exit 1; done

# Each chat's browser pod (two containers per slot), from Docker's labels.
browser-pods-status:
	@docker ps -a $(POD_FILTER) --format 'table {{.Label "happy-browser.slot"}}\t{{.Label "happy-browser.role"}}\t{{.Label "happy-browser.pod_id"}}\t{{.Status}}\t{{.Names}}' | sort -n
	@if curl -fsS --max-time 5 -H "Authorization: Bearer $$(cat $(BROWSER_SECRETS)/bridge-token)" $(BROWSER_BRIDGE)/api/pods >/dev/null 2>&1; then \
		echo; curl -fsS --max-time 5 -H "Authorization: Bearer $$(cat $(BROWSER_SECRETS)/bridge-token)" $(BROWSER_BRIDGE)/api/pods; echo; fi

# Remove the pod containers no chat is using (scripts/pods-reap.mjs): pods with an active
# session, a held link or use in the last REAP_RECENT_MIN (10) minutes are kept, and nothing is
# removed when the bridge does not answer. Lists what it would remove and asks on a terminal;
# without one (or DRY_RUN=1) it only lists. FORCE=1 removes every pod container, no questions.
# Slot directories are wiped by the launcher when the slot is next used; chats' saved logins
# (data/chats) are never touched.
browser-pods-reap:
	@if [ "$(FORCE)" = 1 ]; then \
		ids=$$(docker ps -aq $(POD_FILTER)); if [ -n "$$ids" ]; then docker rm -f $$ids; else echo "no pods"; fi; \
	else BROWSER_BRIDGE="$(BROWSER_BRIDGE)" DRY_RUN="$(DRY_RUN)" REAP_RECENT_MIN="$(REAP_RECENT_MIN)" node $(BROWSER_DIR)/scripts/pods-reap.mjs; fi

# The entrypoint patch against the pinned browser-node image's own /entrypoint.sh: each
# pattern must match exactly once (scripts/browser-node-entrypoint.sh refuses to start otherwise).
browser-entrypoint-check:
	@set -e; t=$$(mktemp -d); trap 'rm -rf "$$t"' EXIT; \
	docker run --rm --network none --entrypoint cat $$(sed -nE 's/^x-browser-node-image: &[a-z_]+ (.+)$$/\1/p' $(BROWSER_DIR)/compose.browser.yml) /entrypoint.sh >"$$t/entrypoint.sh"; \
	for k in 0 1; do \
		BROWSER_KIOSK=$$k BROWSER_NODE_ENTRYPOINT_SRC="$$t/entrypoint.sh" BROWSER_NODE_ENTRYPOINT_OUT="$$t/out.sh" BROWSER_NODE_ENTRYPOINT_DRY_RUN=1 \
			PLAYWRIGHT_SERVER_HOST=127.0.0.1 NOVNC_PORT=6100 bash $(BROWSER_DIR)/scripts/browser-node-entrypoint.sh; \
		grep -qE "fluxbox -rc /happy/fluxbox/init$$([ $$k = 0 ] && echo '\.window') >" "$$t/out.sh"; \
		echo "entrypoint patch (BROWSER_KIOSK=$$k): all five patterns match once; $$(diff "$$t/entrypoint.sh" "$$t/out.sh" | grep -c '^>') lines changed"; \
	done; \
	if BROWSER_KIOSK=yes BROWSER_NODE_ENTRYPOINT_SRC="$$t/entrypoint.sh" BROWSER_NODE_ENTRYPOINT_OUT="$$t/out.sh" BROWSER_NODE_ENTRYPOINT_DRY_RUN=1 \
		PLAYWRIGHT_SERVER_HOST=127.0.0.1 NOVNC_PORT=6100 bash $(BROWSER_DIR)/scripts/browser-node-entrypoint.sh 2>/dev/null; then \
		echo "entrypoint patch: BROWSER_KIOSK=yes was accepted" >&2; exit 1; fi; \
	echo "entrypoint patch: BROWSER_KIOSK other than 0 or 1 is refused"

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

# Restart only the bridge (to load new bridge code). On SIGTERM the bridge releases every held
# link (noVNC sockets close, waiting agents get status released), saves links.json and exits,
# well inside the 20 s given here. Pods are left running and the new bridge adopts them.
# BRIDGE_ENV=1 recreates the container from compose instead (only the bridge, --no-deps), so a
# changed .env.browser setting such as BRIDGE_LAN_BIND takes effect; a plain restart keeps the
# container's old environment.
browser-bridge-restart:
	@docker exec -i $(BROWSER_PROJECT)-bridge-1 node --input-type=module - <$(BROWSER_DIR)/scripts/bridge-restart-check.mjs \
		|| echo "(the bridge is not running: no link is held)"
	$(if $(filter 1,$(BRIDGE_ENV)),$(BROWSER_COMPOSE) up -d --no-deps --force-recreate --timeout 20 bridge,docker restart -t 20 $(BROWSER_PROJECT)-bridge-1)
	@for i in $$(seq 1 30); do curl -fsS --max-time 2 $(BROWSER_BRIDGE)/healthz >/dev/null 2>&1 && break; sleep 1; done
	@printf "bridge /healthz: "; curl -fsS --max-time 5 $(BROWSER_BRIDGE)/healthz || { echo unreachable; exit 1; }; echo

browser-bridge-smoke:
	@BROWSER_API="$(BROWSER_API)" BROWSER_BRIDGE="$(BROWSER_BRIDGE)" HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" \
		BROWSER_NODE_CONTAINER="$(BROWSER_PROJECT)-browser-node-1" node $(BROWSER_DIR)/scripts/bridge-smoke.mjs
