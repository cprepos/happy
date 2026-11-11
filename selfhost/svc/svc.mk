# The vault and browser stacks under happy-svc's rootless Docker daemon (selfhost/svc/README.md).
# Included from selfhost/Makefile. Everything here runs as the operator (prep): the daemon is
# reached only through the root-owned wrapper, via the one sudoers rule setup-root.sh installs.
#
#   make svc-setup-print        the one root command (setup-root.sh) for HEAD, to run yourself
#   make svc-deploy             the root command (deploy-root.sh) to roll HEAD out later
#   make svc-settings           selfhost/svc/.settings/{vault,browser}.env from your current files
#   make svc-up / svc-down      both projects (P=vault|browser for one)
#   make svc-restart P=.. [S=..]
#   make svc-status             containers, published ports, loopback-only check
#   make svc-logs P=.. S=.. [F=1]
#   make svc-init               (once) the vault's volumes, browser secrets, the filler's layout
#   make svc-admin A="token-issue NAME=bridge-client"   a filler admin command
#   make svc-tokens             issue missing client tokens, copy them (0600) to your secrets
#                               dirs, hand the controller token to the filler, clear the outbox
#   make svc-enroll / svc-policy-edit   (terminal, your sudo password) interactive filler admin
#   make svc-backup             a backup now (a timer runs one nightly)
#   make svc-migrate            (cutover) your Docker's volumes and browser home -> the drop
#                               directory, then the password-sudo import commands
#   make svc-test               the wrapper, sudoers and script tests; no root, no Docker

SVC_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
SVC_REPO := $(abspath $(SVC_DIR)/../..)
SVC_CTL_PATH := /usr/local/libexec/happy-svc-ctl
SVC_CTL := sudo -n -u happy-svc $(SVC_CTL_PATH)
SVC_DROP := /var/lib/happy-svc-drop/in
SVC_SETTINGS := $(SVC_DIR)/.settings
SVC_BROWSER_HOME := $(or $(BROWSER_STACK_HOME),$(HAPPY_BROWSER_HOME),$(HOME)/.local/share/happy-browser)
SVC_VAULT_MCP_HOME := $(or $(BROWSER_VAULT_MCP_HOME),$(HAPPY_VAULT_MCP_HOME),$(HOME)/.local/share/happy-vault-mcp)
SVC_HELPER_IMAGE := node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914
SVC_MIGRATE_VOLUMES := happy-vault-data happy-vault-config happy-vault-backups happy-filler
# The keys deploy-root.sh accepts (it checks them again, and the values of BROWSER_NODE_CHROME,
# EVIDENCE_TZ and SCREENSHOT_TIME_MODE; svc-settings runs that check). No BROWSER_NODE_IMAGE:
# with BROWSER_NODE_CHROME=1, happy-svc-ctl builds the node image in happy-svc's daemon itself.
SVC_VAULT_KEYS := VAULT_DOMAIN|VAULT_AGENT_EMAIL|VAULT_OWNER_EMAIL
SVC_BROWSER_KEYS := BROWSER_WIDTH|BROWSER_HEIGHT|BROWSER_KIOSK|BROWSER_VIEWPORT_HEIGHT|MAX_SESSIONS|MCP_TOOL_PROFILE|LOG_LEVEL|REQUEST_RATE_LIMIT_REQUESTS|PII_SCRUB_SCREENSHOT|BRIDGE_PODS|BRIDGE_MAX_PODS|BRIDGE_POD_WARM|BRIDGE_POD_IDLE_MIN|BRIDGE_LINK_IDLE_HOURS|BROWSER_NODE_CHROME|EVIDENCE_TZ|SCREENSHOT_TIME_MODE
# browser.mk's EVIDENCE_TZ default when .env.browser has none: this host's zone.
SVC_EVIDENCE_TZ := $(or $(shell head -n 1 /etc/timezone 2>/dev/null | tr -d '[:space:]'),America/Toronto)
P ?=
S ?=
A ?=
F ?=

.PHONY: svc-help svc-setup-print svc-deploy svc-settings svc-up svc-down svc-restart svc-status svc-logs \
	svc-init svc-admin svc-tokens svc-enroll svc-policy-edit svc-backup svc-migrate svc-test

svc-help:
	@sed -n '3,19p' $(SVC_DIR)/svc.mk | sed 's/^# \{0,1\}//'

svc-setup-print:
	@sha=$$(git -C $(SVC_REPO) rev-parse HEAD); \
	git -C $(SVC_REPO) diff --quiet HEAD -- selfhost/svc selfhost/vault browser-stack || echo "NOTE: uncommitted changes under the release paths are not part of $$sha"; \
	echo "Review, then run yourself (it prints each step; add --dry-run to only print):"; echo; \
	echo "  sudo bash $(SVC_DIR)/setup-root.sh --commit $$sha$(if $(wildcard $(SVC_SETTINGS)/vault.env),$(if $(wildcard $(SVC_SETTINGS)/browser.env), --settings $(SVC_SETTINGS))) [--install-packages]"; \
	echo; echo "Commit: $$(git -C $(SVC_REPO) log -1 --format='%h %s' $$sha)"

svc-deploy:
	@sha=$$(git -C $(SVC_REPO) rev-parse HEAD); \
	echo "Roll out $$(git -C $(SVC_REPO) log -1 --format='%h %s' $$sha) (run yourself, then make svc-up):"; echo; \
	echo "  sudo bash $(SVC_DIR)/deploy-root.sh $$sha$(if $(wildcard $(SVC_SETTINGS)/vault.env),$(if $(wildcard $(SVC_SETTINGS)/browser.env), --settings $(SVC_SETTINGS)))"

# Only the accepted keys, copied from selfhost/vault/.env and browser-stack/browser/.env.browser
# (plus EVIDENCE_TZ as browser.mk defaults it), then checked as deploy-root.sh will check them.
svc-settings:
	@install -d -m 0700 $(SVC_SETTINGS)
	@ts=$$(date -u +%Y%m%dT%H%M%SZ); \
	for pair in "vault.env:$(SVC_REPO)/selfhost/vault/.env:$(SVC_VAULT_KEYS)" "browser.env:$(SVC_REPO)/browser-stack/browser/.env.browser:$(SVC_BROWSER_KEYS)"; do \
		name=$${pair%%:*}; rest=$${pair#*:}; src=$${rest%%:*}; keys=$${rest#*:}; dst=$(SVC_SETTINGS)/$$name; \
		tmp=$$dst.new-$$ts; (umask 077; grep -E "^($$keys)=[A-Za-z0-9@._:,/+-]*$$" "$$src" 2>/dev/null >"$$tmp" || true); \
		if [ "$$name" = browser.env ] && ! grep -q '^EVIDENCE_TZ=' "$$tmp"; then echo "EVIDENCE_TZ=$(SVC_EVIDENCE_TZ)" >>"$$tmp"; fi; \
		if [ -e "$$dst" ] && ! cmp -s "$$tmp" "$$dst"; then install -d -m 0700 $(SVC_SETTINGS)/old-$$ts; mv "$$dst" $(SVC_SETTINGS)/old-$$ts/; fi; \
		mv -T "$$tmp" "$$dst"; echo "$$dst: $$(cut -d= -f1 "$$dst" | tr '\n' ' ')"; \
	done; bash $(SVC_DIR)/deploy-root.sh --check-settings $(SVC_SETTINGS); \
	echo "Check them, then: make svc-deploy (or svc-setup-print)"

svc-up:
	$(SVC_CTL) up $(P)

svc-down:
	$(SVC_CTL) down $(P)

svc-restart:
	@test -n "$(P)" || { echo "$@: P=vault|browser [S=service]" >&2; exit 2; }
	$(SVC_CTL) restart $(P) $(S)

svc-status:
	@$(SVC_CTL) status

svc-logs:
	@test -n "$(P)" -a -n "$(S)" || { echo "$@: P=vault|browser S=service [F=1]" >&2; exit 2; }
	$(SVC_CTL) logs $(P) $(S) $(if $(filter 1,$(F)),follow)

svc-init:
	$(SVC_CTL) init

svc-admin:
	@test -n "$(A)" || { echo "$@: A=\"<subcommand> [args]\"" >&2; exit 2; }
	$(SVC_CTL) admin $(A)

# The tokens come back on stdout, already checked by the wrapper; each goes into a new 0600
# file of yours (an old, different copy is moved to old-<ts>/ beside it).
svc-tokens:
	@set -e; \
	missing=$$($(SVC_CTL) admin tokens-missing | tr -d '\r'); \
	for n in bridge-client vault-client; do \
		if printf '%s\n' "$$missing" | grep -qw "$$n"; then $(SVC_CTL) admin token-issue NAME=$$n; fi; \
	done; \
	ts=$$(date -u +%Y%m%dT%H%M%SZ); all=$$($(SVC_CTL) tokens-export); \
	printf '%s\n' "$$all" | while read -r name val; do \
		case $$name in \
			bridge-client-token) dst=$(SVC_BROWSER_HOME)/secrets/filler-client-token ;; \
			vault-client-token) dst=$(SVC_VAULT_MCP_HOME)/secrets/vault-client-token ;; \
			api-token) dst=$(SVC_BROWSER_HOME)/secrets/api-token ;; \
			*) continue ;; \
		esac; \
		dir=$${dst%/*}; install -d -m 0700 "$$dir"; tmp="$$dir/.$$name.svc-$$ts"; \
		(umask 077; printf '%s\n' "$$val" >"$$tmp"); \
		if [ -e "$$dst" ] && ! cmp -s "$$tmp" "$$dst"; then install -d -m 0700 "$$dir/old-$$ts"; mv "$$dst" "$$dir/old-$$ts/"; fi; \
		mv -T "$$tmp" "$$dst"; echo "$@: $$name -> $$dst"; \
	done; \
	$(SVC_CTL) controller-token; \
	$(SVC_CTL) admin outbox-clear; \
	echo "$@: done; restart the host bridge MCP to pick up a new bridge token"

svc-enroll:
	sudo -u happy-svc $(SVC_CTL_PATH) admin-tty enroll

svc-policy-edit:
	sudo -u happy-svc $(SVC_CTL_PATH) admin-tty policy-edit

svc-backup:
	$(SVC_CTL) backup

# Cutover: stop the stacks on your Docker, tar each volume (from a container, since the files
# belong to the containers' uids) and the browser home into the drop directory, then print
# the imports. The tarballs are 0644 inside in/, which only you and happy-svc can enter.
svc-migrate:
	@set -e; \
	test -d $(SVC_DROP) -a -w $(SVC_DROP) || { echo "$@: $(SVC_DROP) missing or not writable; run setup-root.sh first" >&2; exit 1; }; \
	if [ -n "$$(docker ps -q --filter label=com.docker.compose.project=happy-vault)$$(docker ps -q --filter label=com.docker.compose.project=happy-browser)" ]; then \
		echo "$@: the stacks are still running on your Docker; make stack-down first" >&2; exit 1; fi; \
	for v in $(SVC_MIGRATE_VOLUMES); do \
		docker volume inspect $$v >/dev/null 2>&1 || { echo "$@: $$v: no such volume, skipped"; continue; }; \
		test ! -e $(SVC_DROP)/$$v.tar || { echo "$@: $(SVC_DROP)/$$v.tar already there, skipped"; continue; }; \
		(umask 022; docker run --rm --network none --read-only -v $$v:/src:ro $(SVC_HELPER_IMAGE) tar -C /src -cf - . >$(SVC_DROP)/.$$v.tar.part); \
		mv -T $(SVC_DROP)/.$$v.tar.part $(SVC_DROP)/$$v.tar; echo "$@: $$v -> $(SVC_DROP)/$$v.tar"; \
	done; \
	if [ -d $(SVC_BROWSER_HOME) ] && [ ! -e $(SVC_DROP)/browser-home.tar ]; then \
		(umask 022; docker run --rm --network none --read-only -v $(SVC_BROWSER_HOME):/src:ro $(SVC_HELPER_IMAGE) tar -C /src -cf - . >$(SVC_DROP)/.browser-home.tar.part); \
		mv -T $(SVC_DROP)/.browser-home.tar.part $(SVC_DROP)/browser-home.tar; echo "$@: $(SVC_BROWSER_HOME) -> $(SVC_DROP)/browser-home.tar"; \
	fi; \
	echo; echo "Now import each (your sudo password; each refuses to overwrite):"; \
	for v in $(SVC_MIGRATE_VOLUMES) browser-home; do test -e $(SVC_DROP)/$$v.tar && echo "  sudo -u happy-svc $(SVC_CTL_PATH) import $$v"; done; \
	echo "Your own copies stay where they are; move them aside only after make svc-status is healthy."

svc-test:
	bash $(SVC_DIR)/test/run.sh
