# The secret filler (selfhost/browser/filler): types vault secrets into the
# agent's browser by name, so the agent never sees a value. Its own compose
# project (happy-filler). Included from selfhost/Makefile via `-include filler.mk`.
# See selfhost/browser/filler/README.md.
#
#   make filler-init             (sudo) /srv/happy-filler, client token, controller-token copy, empty policy
#   make filler-install COMMIT=  (sudo) deploy a reviewed commit to /srv/happy-filler/releases/<sha>
#   make filler-enroll           (sudo, interactive) enroll with the agent's vault account
#   make filler-up / filler-down / filler-logs
#   make filler-lock             stop the filler (its keys leave memory); filler-up unlocks from the key files
#   make filler-status           container, 127.0.0.1-only bind on 6091, /healthz, policy check
#   make filler-policy-edit      (sudo) back up, sudoedit, then validate /srv/happy-filler/policy.json
#   make filler-audit            the newest audit lines (FILLER_AUDIT_LINES=50)
#   make filler-test             unit tests (node:test)
#   make filler-smoke            canary end-to-end: a separate filler + fake vault + fake page, leak sweep

FILLER_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/browser/filler
FILLER_REPO := $(abspath $(FILLER_DIR)/../../..)
FILLER_ROOT := /srv/happy-filler
FILLER_COMPOSE := docker compose -p happy-filler -f $(FILLER_ROOT)/current/compose.filler.yml
FILLER_URL ?= http://127.0.0.1:6091
FILLER_AUDIT_LINES ?= 50
FILLER_HOME_DIR := $(or $(HAPPY_BROWSER_HOME),$(HOME)/.local/share/happy-browser)
FILLER_IMAGE = $(shell awk '/^ *image: node:/{print $$2; exit}' $(FILLER_DIR)/compose.filler.yml)
COMMIT ?=

.PHONY: filler-init filler-install filler-enroll filler-up filler-down filler-lock filler-logs filler-status \
	filler-policy-edit filler-audit filler-test filler-smoke

filler-init:
	sudo HAPPY_BROWSER_HOME="$(FILLER_HOME_DIR)" FILLER_ROTATE="$(FILLER_ROTATE)" bash $(FILLER_DIR)/scripts/filler-init.sh

filler-install:
	sudo FILLER_REPO="$(FILLER_REPO)" COMMIT="$(COMMIT)" bash $(FILLER_DIR)/scripts/filler-install.sh

filler-enroll:
	sudo bash $(FILLER_DIR)/scripts/filler-enroll.sh

filler-up:
	@test -e $(FILLER_ROOT)/current/compose.filler.yml || { echo "run make filler-init and make filler-install COMMIT=<sha> first"; exit 1; }
	$(FILLER_COMPOSE) up -d --force-recreate --wait

filler-down:
	$(FILLER_COMPOSE) down

filler-lock:
	$(FILLER_COMPOSE) stop
	@echo "filler locked (stopped); make filler-up unlocks it from its key files"

filler-logs:
	$(FILLER_COMPOSE) logs -f --tail=200

filler-status:
	@echo "== secret filler (happy-filler)"
	@if [ -e $(FILLER_ROOT)/current ]; then echo "release: $$(cat $(FILLER_ROOT)/current/COMMIT 2>/dev/null)"; \
		$(FILLER_COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}'; else echo "not installed (make filler-init, make filler-install COMMIT=<sha>)"; fi
	@echo "listening on 6091 (expect 127.0.0.1 only):"
	@ss -ltnH | awk '{print $$4}' | grep -E ':6091$$' | sort -u || echo "  (none)"
	@if ss -ltnH | awk '{print $$4}' | grep -E ':6091$$' | grep -qvE '^127\.0\.0\.1:'; then \
		echo "WARNING: 6091 is bound beyond 127.0.0.1"; exit 1; fi
	@printf "healthz: "; curl -fs --max-time 5 $(FILLER_URL)/healthz || printf "unreachable"; echo
	@printf "bridge client token: "; test -s $(FILLER_HOME_DIR)/secrets/filler-client-token && echo present || echo "absent (bridge secret tools off)"

filler-policy-edit:
	@test -e $(FILLER_ROOT)/policy.json || { echo "run make filler-init first"; exit 1; }
	sudo cp -p $(FILLER_ROOT)/policy.json $(FILLER_ROOT)/policy-backups/policy.$$(date -u +%Y%m%dT%H%M%SZ).json
	sudoedit $(FILLER_ROOT)/policy.json
	sudo chown root:1990 $(FILLER_ROOT)/policy.json
	sudo chmod 0640 $(FILLER_ROOT)/policy.json
	docker run --rm --network none --user 1990:1990 --read-only --cap-drop ALL \
		-v $(FILLER_ROOT)/current/app:/app:ro -v $(FILLER_ROOT)/policy.json:/filler/policy.json:ro \
		$(FILLER_IMAGE) node /app/server.mjs --check-policy /filler/policy.json
	@echo "the running filler reloads the policy on its own"

filler-audit:
	@ls -1 $(FILLER_ROOT)/audit/*.jsonl >/dev/null 2>&1 || { echo "no audit yet"; exit 0; }
	@tail -q -n $(FILLER_AUDIT_LINES) $$(ls -1 $(FILLER_ROOT)/audit/*.jsonl | sort | tail -n 2) | tail -n $(FILLER_AUDIT_LINES)

filler-test:
	cd $(FILLER_DIR) && node --test --test-timeout=30000 test/*.test.mjs

filler-smoke:
	cd $(FILLER_DIR) && timeout 120 node test/smoke.mjs
