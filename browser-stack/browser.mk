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
#   make browser-controller-scroll-test the patch's scroll against a real Chromium (throwaway containers)
#   make browser-bridge-smoke  end-to-end against the running stack: session, link, page, frame, takeover, done
#   make browser-bridge-restart  restart only the bridge container; lists the held links it releases on the way down
#   make browser-pod-bench     pod start times, cold and warm (test project only)
#   make browser-pod-smoke     per-chat pods end to end (bridge with BRIDGE_PODS=1)
#   make browser-pods-reap     remove pods no chat is using (asks first; DRY_RUN=1 lists only, FORCE=1 removes all)
#   make browser-node-chrome   build the browser node with Google Chrome (node-chrome/; used when BROWSER_NODE_CHROME=1)

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
# The Docker daemon's socket (prep's rootful daemon), which only the docker-proxy container
# mounts, and its group, which that container is given; compose.browser.yml requires it.
export HAPPY_DOCKER_SOCKET ?= /var/run/docker.sock
export DOCKER_SOCKET_GID ?= $(shell stat -c %g $(HAPPY_DOCKER_SOCKET) 2>/dev/null)
BROWSER_LOCAL_ENV := $(BROWSER_DIR)/.env.browser
# The browser node's browser (BROWSER_NODE_CHROME in .env.browser): 0, the default, the upstream
# image's bundled Chrome for Testing; 1, Google Chrome stable, from the image node-chrome/Dockerfile
# builds locally (make browser-node-chrome; browser-up builds it first). compose runs it for
# browser-node and every pod as BROWSER_NODE_IMAGE, named by its local image id, read when each
# compose command runs, after the build. Never push that image: Google Chrome may not be
# redistributed. A different node image can be given as BROWSER_NODE_IMAGE in .env.browser.
BROWSER_NODE_CHROME ?= $(or $(shell sed -nE 's/^BROWSER_NODE_CHROME=([^[:space:]]*)[[:space:]]*$$/\1/p' $(BROWSER_LOCAL_ENV) 2>/dev/null | tail -1),0)
NODE_CHROME_DIR := $(BROWSER_DIR)/node-chrome
# The tag: Chrome's version (without the .deb revision) and the Dockerfile's IMAGE_REVISION, e.g.
# 157.0.8103.50-2; the revision goes up for a change to the image that keeps the same Chrome.
NODE_CHROME_VERSION := $(shell sed -nE 's/^ARG CHROME_VERSION=([0-9.]+)-[0-9]+$$/\1/p' $(NODE_CHROME_DIR)/Dockerfile)
NODE_CHROME_REVISION := $(shell sed -nE 's/^ARG IMAGE_REVISION=([0-9]+)$$/\1/p' $(NODE_CHROME_DIR)/Dockerfile)
NODE_CHROME_TAG := happy-browser-node-chrome:$(NODE_CHROME_VERSION)-$(NODE_CHROME_REVISION)
BROWSER_NODE_IMAGE_ENV := $(if $(filter 1,$(BROWSER_NODE_CHROME)),BROWSER_NODE_IMAGE="$$(docker image inspect -f '{{.Id}}' $(NODE_CHROME_TAG) 2>/dev/null || echo not-built:run-make-browser-node-chrome)")
BROWSER_COMPOSE := $(BROWSER_NODE_IMAGE_ENV) docker compose -p $(BROWSER_PROJECT) -f $(BROWSER_DIR)/compose.browser.yml \
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
# UI). The page's height follows: the whole screen in kiosk mode, otherwise the screen less the
# desktop panel (BROWSER_PANEL_HEIGHT: the toolbar.height of kiosk/fluxbox/init.window, when its
# toolbar is visible) and Chromium's tab strip and toolbar (CHROME_UI_HEIGHT, measured on the
# pinned image). Exported, so compose (and through it the launcher, for every pod) uses these over
# .env.browser's.
BROWSER_KIOSK ?= $(or $(shell sed -nE 's/^BROWSER_KIOSK=([^[:space:]]*)[[:space:]]*$$/\1/p' $(BROWSER_LOCAL_ENV) 2>/dev/null | tail -1),0)
BROWSER_HEIGHT ?= $(or $(shell sed -nE 's/^BROWSER_HEIGHT=([0-9]+)[[:space:]]*$$/\1/p' $(BROWSER_LOCAL_ENV) 2>/dev/null | tail -1),1200)
BROWSER_WIDTH ?= $(or $(shell sed -nE 's/^BROWSER_WIDTH=([0-9]+)[[:space:]]*$$/\1/p' $(BROWSER_LOCAL_ENV) 2>/dev/null | tail -1),1920)
FLUXBOX_WINDOW_INIT = $(BROWSER_DIR)/kiosk/fluxbox/init.window
# scripts/browser-geometry.sh works the numbers out (and checks them), as happy-svc-ctl does too;
# on a bad value it says why and BROWSER_VIEWPORT_HEIGHT is left empty, so compose refuses to start.
BROWSER_GEOMETRY := $(shell BROWSER_KIOSK='$(BROWSER_KIOSK)' BROWSER_HEIGHT='$(BROWSER_HEIGHT)' BROWSER_WIDTH='$(BROWSER_WIDTH)' \
	sh $(BROWSER_DIR)/scripts/browser-geometry.sh $(FLUXBOX_WINDOW_INIT))
browser_geometry = $(patsubst $(1)=%,%,$(filter $(1)=%,$(BROWSER_GEOMETRY)))
CHROME_UI_HEIGHT := $(call browser_geometry,CHROME_UI_HEIGHT)
BROWSER_PANEL_HEIGHT := $(call browser_geometry,BROWSER_PANEL_HEIGHT)
BROWSER_VIEWPORT_HEIGHT ?= $(call browser_geometry,BROWSER_VIEWPORT_HEIGHT)
export BROWSER_KIOSK BROWSER_HEIGHT BROWSER_PANEL_HEIGHT BROWSER_VIEWPORT_HEIGHT
# The zone of the desktop panel's clock (the browser node's TZ) and of the screenshot audit (an
# IANA name): the host's own (/etc/timezone), else America/Toronto. The controller refuses a bad one.
EVIDENCE_TZ ?= $(or $(shell cat /etc/timezone 2>/dev/null | head -1 | tr -d '[:space:]'),America/Toronto)
export EVIDENCE_TZ
BROWSER_BIND_OK = ^127\.0\.0\.1:$(if $(BRIDGE_LAN_BIND),|^$(subst .,\.,$(BRIDGE_LAN_BIND)):$(BRIDGE_LAN_PORT)$$)
# Each anchor's pinned default (the node's is written $${BROWSER_NODE_IMAGE:-<image>}).
COMPOSE_IMAGE = $(shell sed -nE 's/^x-$(1)-image: &[a-z_]+ (\$$\{[A-Z_]+:-)?([^}[:space:]]+)\}?[[:space:]]*$$/\2/p' $(BROWSER_DIR)/compose.browser.yml)
BROWSER_IMAGES = $(call COMPOSE_IMAGE,browser-node) $(call COMPOSE_IMAGE,controller) \
	$(shell sed -nE 's/^    image: (node:.+)$$/\1/p' $(BROWSER_DIR)/compose.browser.yml | sort -u)
POD_FILTER = --filter label=happy-browser.pod=1 --filter label=happy-browser.project=$(BROWSER_PROJECT)

.PHONY: browser-init browser-up browser-down browser-status browser-logs browser-verify browser-bridge-test browser-bridge-smoke browser-bridge-restart \
	browser-pull browser-pods-status browser-pods-reap browser-entrypoint-check \
	browser-pod-bench browser-pod-smoke browser-controller-patch-test browser-controller-scroll-test browser-node-chrome

browser-init:
	@HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" bash $(BROWSER_DIR)/scripts/browser-init.sh

browser-up: browser-init $(if $(filter 1,$(BROWSER_NODE_CHROME)),browser-node-chrome)
	$(BROWSER_COMPOSE) up -d --wait

# The browser node with Google Chrome (node-chrome/Dockerfile), on top of the pinned upstream node
# image: one exact Chrome version, its .deb checked against a pinned SHA256, no update path left in
# the image. Local only (no push). Cached: a rebuild with nothing changed is a no-op.
browser-node-chrome:
	@test -n "$(NODE_CHROME_VERSION)" || { echo "node-chrome/Dockerfile has no ARG CHROME_VERSION" >&2; exit 1; }
	@test -n "$(NODE_CHROME_REVISION)" || { echo "node-chrome/Dockerfile has no ARG IMAGE_REVISION" >&2; exit 1; }
	docker build -t $(NODE_CHROME_TAG) $(NODE_CHROME_DIR)
	@echo "$(NODE_CHROME_TAG): $$(docker image inspect -f '{{.Id}}' $(NODE_CHROME_TAG)); $$(docker run --rm --network none --entrypoint /opt/google/chrome/chrome $(NODE_CHROME_TAG) --version 2>/dev/null)"

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

# The controller patch (controller-patch/happy_live_frames.py) in a throwaway container of the
# pinned controller image, no network: its pin check against the image's files, then its tests.
CONTROLLER_IMAGE = $(call COMPOSE_IMAGE,controller)
browser-controller-patch-test:
	docker run --rm --name happy-controller-patch-test-$$$$ --network none --entrypoint python \
		-e PYTHONPATH=/happy/controller-patch -e HAPPY_LIVE_FRAMES_NO_AUTOLOAD=1 -w /app \
		-v $(BROWSER_DIR)/controller-patch:/happy/controller-patch:ro $(CONTROLLER_IMAGE) \
		-m unittest -v test_happy_live_frames

# The scroll patch against a real Chromium: a throwaway Playwright server in the pinned browser-node
# image and the pinned controller image on their own internal network (no route out), both removed after.
browser-controller-scroll-test:
	@set -e; n=happy-scroll-test-$$$$; \
	docker network create --internal $$n >/dev/null; \
	trap 'docker rm -f $$n-node >/dev/null 2>&1; docker network rm $$n >/dev/null 2>&1' EXIT; \
	docker run -d --rm --name $$n-node --network $$n --network-alias node --entrypoint node -w /opt/browser-node \
		$(call COMPOSE_IMAGE,browser-node) --input-type=module \
		-e "import { chromium } from 'playwright'; await chromium.launchServer({ headless: true, chromiumSandbox: false, host: '0.0.0.0', port: 9223, wsPath: '/scroll-test' }); console.log('ready');" >/dev/null; \
	for i in $$(seq 1 60); do docker logs $$n-node 2>&1 | grep -q ready && break; sleep 0.5; done; \
	docker run --rm --name $$n-ctl --network $$n --entrypoint python \
		-e PYTHONPATH=/happy/controller-patch -e HAPPY_LIVE_FRAMES_NO_AUTOLOAD=1 -e HAPPY_SCROLL_TEST_WS=ws://node:9223/scroll-test -w /app \
		-v $(BROWSER_DIR)/controller-patch:/happy/controller-patch:ro $(CONTROLLER_IMAGE) \
		-m unittest -v test_scroll_browser

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
	docker run --rm --network none --entrypoint cat $(call COMPOSE_IMAGE,browser-node) /entrypoint.sh >"$$t/entrypoint.sh"; \
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
