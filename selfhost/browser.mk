# Live browser stack (auto-browser + the live bridge). Included from selfhost/Makefile via
# `-include browser.mk`; also usable directly: `make -f browser.mk browser-status`.
# See selfhost/browser/README.md.
#
#   make browser-init     generate secrets under ~/.local/share/happy-browser/secrets (600, idempotent)
#   make browser-up       start browser-node + controller (detached), loopback-only
#   make browser-down     stop and remove the containers (data and secrets kept)
#   make browser-status   container health, loopback binds, controller /healthz
#   make browser-logs     follow logs (BROWSER_SVC=controller to pick one service)
#   make browser-verify   MCP answers with the token (tools/list), refuses without it; noVNC demands a password

BROWSER_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/browser
export HAPPY_BROWSER_HOME ?= $(HOME)/.local/share/happy-browser
BROWSER_SECRETS := $(HAPPY_BROWSER_HOME)/secrets
BROWSER_LOCAL_ENV := $(BROWSER_DIR)/.env.browser
BROWSER_COMPOSE := docker compose -p happy-browser -f $(BROWSER_DIR)/compose.browser.yml \
	--env-file $(BROWSER_SECRETS)/browser.env $(if $(wildcard $(BROWSER_LOCAL_ENV)),--env-file $(BROWSER_LOCAL_ENV))
BROWSER_SVC ?=
BROWSER_API ?= http://127.0.0.1:8010

.PHONY: browser-init browser-up browser-down browser-status browser-logs browser-verify

browser-init:
	@HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" bash $(BROWSER_DIR)/scripts/browser-init.sh

browser-up: browser-init
	$(BROWSER_COMPOSE) up -d --wait

browser-down:
	$(BROWSER_COMPOSE) down

browser-status:
	@$(BROWSER_COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
	@echo
	@echo "listening on the live-browser ports (expect 127.0.0.1 only):"
	@ss -ltnH | awk '{print $$4}' | grep -E ':(6080|8010|6090)$$' | sort -u || echo "  (none)"
	@if ss -ltnH | awk '{print $$4}' | grep -E ':(6080|8010|6090)$$' | grep -qvE '^127\.0\.0\.1:'; then \
		echo "WARNING: a live-browser port is bound beyond 127.0.0.1"; exit 1; fi
	@printf "controller /healthz: "; curl -fsS --max-time 5 $(BROWSER_API)/healthz || echo "unreachable"; echo

browser-logs:
	$(BROWSER_COMPOSE) logs -f --tail=200 $(BROWSER_SVC)

browser-verify:
	@BROWSER_API="$(BROWSER_API)" HAPPY_BROWSER_HOME="$(HAPPY_BROWSER_HOME)" bash $(BROWSER_DIR)/scripts/browser-verify.sh
