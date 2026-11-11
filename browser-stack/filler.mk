# The secret filler (browser-stack/browser/filler): types vault secrets into the
# agent's browser by name, so the agent never sees a value. It runs in Docker,
# as the service filler of the vault's compose project (happy-vault,
# selfhost/vault/compose.vault.yml), uid 1990, with its data in the named
# volume happy-filler. Its admin commands run once each in the same image
# (service filler-admin, scripts/admin.mjs), and the operator's side of the
# token handoffs and the audit in service filler-operator (uid 1989, the
# filler's group); none needs a separate account, su or sudo.
# Included from browser-stack/Makefile and selfhost/Makefile.
# See browser-stack/browser/filler/README.md.
#
# The setup in one place is selfhost/vault.mk: make vault-init, vault-up,
# vault-tokens, vault-enroll BACKEND=shared, vault-status.
#
#   make filler-build / filler-up / filler-down / filler-restart / filler-lock / filler-logs
#                                filler-down and filler-lock stop the container (its keys leave
#                                memory); it stays stopped across reboots until filler-up
#   make filler-token-issue NAME=bridge-client|vault-client [FILLER_ROTATE=1]
#                                a new client token: hash kept, plaintext once to outbox/<NAME>-token
#                                (make vault-tokens does this and the take below)
#   make filler-controller-token-take   inbox/controller-token -> secrets/controller-token (0400)
#   make filler-init             directories and an empty policy (fresh install; make vault-init runs it)
#   make filler-enroll           (terminal) enroll with the agent's vault account (= make vault-enroll)
#   make filler-seed-policy      seed an empty policy with default_client "agent"
#   make filler-policy-edit      (terminal) back up, edit a copy (vi), validate, swap it in
#   make filler-policy-upgrade   once: an older policy (no pipe_targets) gets manage + pipe_targets
#   make filler-items            the agent account's logins: name, item id, https hosts (no values)
#   make filler-outbox-clear     move tokens nobody has taken to trash/ in the volume
#
# The operator's side (prep):
#   make filler-status           container, 127.0.0.1-only bind on 6091, /healthz (unlocked), tokens
#   make filler-audit            the newest audit lines (FILLER_AUDIT_LINES=50)
#   make filler-token-take       outbox tokens -> prep's secrets dirs (0600)
#   make filler-controller-token-give   the browser controller token -> inbox/ in the volume
#   make filler-test             unit tests (node:test)
#   make filler-smoke            canary end-to-end: a separate filler + fake vault + fake page, leak sweep
#   make vault-mcp-test          unit tests of the vault tools' MCP server (browser-stack/vault-mcp)

FILLER_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/browser/filler
FILLER_REPO := $(abspath $(FILLER_DIR)/../../..)
# The old systemd unit's tree, until make vault-filler-cutover (selfhost/vault.mk).
FILLER_ROOT ?= /srv/happy-filler
FILLER_UID ?= 1990
# The filler's compose project (it is the vault's) and its one-off admin runs.
FILLER_COMPOSE := docker compose -p happy-vault -f $(FILLER_REPO)/selfhost/vault/compose.vault.yml
FILLER_ADMIN_RUN := $(FILLER_COMPOSE) --profile admin run --rm --no-deps
# The operator's window into the volume: outbox/ and audit/ read-only, inbox/ writable, nothing else.
FILLER_OPERATOR_RUN := $(FILLER_ADMIN_RUN) -T filler-operator
FILLER_CONTAINER := happy-vault-filler-1
FILLER_URL ?= http://127.0.0.1:6091
FILLER_AUDIT_LINES ?= 50
FILLER_HOME_DIR := $(or $(BROWSER_STACK_HOME),$(HAPPY_BROWSER_HOME),$(HOME)/.local/share/happy-browser)
# Where vault-mcp (browser-stack/vault-mcp) finds its token for the filler's /v1/vault/* routes.
VAULT_MCP_HOME_DIR := $(or $(BROWSER_VAULT_MCP_HOME),$(HAPPY_VAULT_MCP_HOME),$(HOME)/.local/share/happy-vault-mcp)
VAULT_MCP_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/vault-mcp
NAME ?=

# Something else on 6091 (the old happy-filler systemd user unit) blocks the container: say how to stop it.
FILLER_PORT_GUARD = @if [ "$$(docker container inspect -f '{{.State.Running}}' $(FILLER_CONTAINER) 2>/dev/null)" != true ] \
	&& ss -ltnH | awk '{print $$4}' | grep -qE ':6091$$'; then \
	echo "$@: 127.0.0.1:6091 is taken by something other than the filler container (the old systemd unit?)." >&2; \
	echo "  stop it first: sudo -u happy-filler XDG_RUNTIME_DIR=/run/user/1990 systemctl --user disable --now happy-filler.service" >&2; \
	exit 1; fi
# Operator-side targets work on prep's own files; not as root, not as the filler's uid.
FILLER_AS_OPERATOR = @if [ "$$(id -u)" = 0 ] || [ "$$(id -u)" = "$(FILLER_UID)" ]; then echo "$@: run as your own account (prep)" >&2; exit 1; fi

FILLER_ADMIN_TARGETS := filler-init filler-enroll filler-seed-policy filler-policy-edit filler-items filler-outbox-clear \
	filler-policy-upgrade filler-token-issue filler-controller-token-take
FILLER_SERVICE_TARGETS := filler-build filler-up filler-down filler-restart filler-lock filler-logs filler-wait

.PHONY: filler-account-setup filler-install filler-setup $(FILLER_ADMIN_TARGETS) $(FILLER_SERVICE_TARGETS) \
	filler-status filler-audit filler-token-take filler-controller-token-give filler-test filler-smoke vault-mcp-test

filler-build:
	$(FILLER_COMPOSE) build filler

filler-up:
	$(FILLER_PORT_GUARD)
	$(FILLER_COMPOSE) up -d --build --wait filler
	@$(MAKE) --no-print-directory filler-wait

filler-down filler-lock:
	$(FILLER_COMPOSE) stop filler
	@echo "$@: stopped (its keys left memory); it stays stopped until make filler-up"

filler-restart:
	$(FILLER_COMPOSE) restart filler
	@$(MAKE) --no-print-directory filler-wait

filler-logs:
	$(FILLER_COMPOSE) logs -f --tail=200 filler

# Up to 20 s for /healthz, then whether the vault is unlocked.
filler-wait:
	@for i in $$(seq 1 40); do out="$$(curl -fs --max-time 2 $(FILLER_URL)/healthz 2>/dev/null)" && { echo "healthz: $$out"; exit 0; }; sleep 0.5; done; \
	echo "healthz: unreachable after 20 s; see make filler-logs" >&2; exit 1

# Admin commands, inside the image (scripts/admin.mjs). -T: no terminal needed.
filler-init filler-items filler-outbox-clear filler-controller-token-take:
	$(FILLER_ADMIN_RUN) -T filler-admin $(patsubst filler-%,%,$@)

# Once, for a policy from before pipe_targets; the filler reloads it on change.
filler-policy-upgrade:
	$(FILLER_ADMIN_RUN) -T filler-admin policy-upgrade

filler-enroll filler-policy-edit:
	$(FILLER_ADMIN_RUN) filler-admin $(patsubst filler-%,%,$@)

filler-seed-policy:
	$(FILLER_ADMIN_RUN) -T filler-admin seed-policy CLIENT="$(or $(FILLER_DEFAULT_CLIENT),agent)"

filler-token-issue:
	$(FILLER_ADMIN_RUN) -T filler-admin token-issue NAME="$(NAME)" $(if $(FILLER_ROTATE),ROTATE="$(FILLER_ROTATE)")

# The happy-filler account, its systemd unit and the reviewed-release installs
# are gone: the filler is a container built from this tree.
filler-account-setup filler-install filler-setup:
	@echo "$@: no longer used; the filler runs in Docker now. Set up with (in selfhost/):" >&2
	@echo "  make vault-init, make vault-up, make vault-tokens, make filler-seed-policy, make vault-enroll BACKEND=shared" >&2
	@exit 1

filler-status:
	@echo "== secret filler ($(FILLER_CONTAINER))"
	@printf "container: "; docker container inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} since {{.State.StartedAt}} image {{.Image}}' $(FILLER_CONTAINER) 2>/dev/null | cut -c1-110 || echo "none (make vault-up)"
	@printf "process (uid $(FILLER_UID)): "; ps -o uid=,pid=,etime= -C node 2>/dev/null | awk '$$1=="$(FILLER_UID)"{print $$2, $$3; f=1} END{if(!f) print "not running"}'
	@if ps -o uid=,args= -C node 2>/dev/null | grep -qE '^ *$(FILLER_UID) .*$(FILLER_ROOT)/current/'; then echo "note: the old happy-filler systemd unit is running (it holds 6091; the container cannot start)"; fi
	@echo "listening on 6091 (expect 127.0.0.1 only):"
	@ss -ltnH | awk '{print $$4}' | grep -E ':6091$$' | sort -u || echo "  (none)"
	@if ss -ltnH | awk '{print $$4}' | grep -E ':6091$$' | grep -qvE '^127\.0\.0\.1:'; then \
		echo "WARNING: 6091 is bound beyond 127.0.0.1"; exit 1; fi
	@printf "healthz: "; curl -fs --max-time 5 $(FILLER_URL)/healthz || printf "unreachable"; echo
	@printf "bridge client token: "; test -s $(FILLER_HOME_DIR)/secrets/filler-client-token && echo present || echo "absent (bridge secret tools off)"
	@printf "vault-mcp token: "; test -s $(VAULT_MCP_HOME_DIR)/secrets/vault-client-token && echo present || echo "absent (vault tools off)"
	@w="$$($(FILLER_OPERATOR_RUN) 'ls /handoff/outbox' 2>/dev/null | tr '\n' ' ')"; \
		if [ -n "$$w" ]; then echo "tokens waiting in outbox/: $$w(make filler-token-take)"; fi

filler-audit:
	@$(FILLER_OPERATOR_RUN) 'cd /handoff/audit; set -- $$(ls -1 | grep -E "\.jsonl$$" | sort | tail -n 2); \
		if [ $$# -eq 0 ]; then echo "no audit yet"; else tail -q -n "$$0" "$$@" | tail -n "$$0"; fi' $(FILLER_AUDIT_LINES)

# prep's side of a client-token handoff. filler-token-issue leaves each new
# token in outbox/ (the file uid 1990's, 0640, group 1990). The operator
# container (uid 1989, group 1990) checks it with scripts/handoff-copy.mjs (a
# regular file, one link, not its own, token-shaped) and prints it into a new
# 0600 file of prep's (an old different one goes to old-<ts>/); the outbox file
# then moves to trash/<ts>-taken/ in the volume.
filler-token-take:
	$(FILLER_AS_OPERATOR)
	@set -e; ts=$$(date -u +%Y%m%dT%H%M%SZ); n=0; \
	waiting="$$($(FILLER_OPERATOR_RUN) 'ls /handoff/outbox')" || { echo "$@: cannot read outbox/; run make vault-init first" >&2; exit 1; }; \
	for pair in bridge-client-token:$(FILLER_HOME_DIR)/secrets/filler-client-token vault-client-token:$(VAULT_MCP_HOME_DIR)/secrets/vault-client-token; do \
		name=$${pair%%:*}; dst=$${pair#*:}; dir=$${dst%/*}; \
		printf '%s\n' $$waiting | grep -qxF "$$name" || continue; \
		install -d -m 0700 "$$dir"; tmp="$$dir/.$$name.take-$$ts"; \
		if ! (umask 077; $(FILLER_OPERATOR_RUN) 'node scripts/handoff-copy.mjs "/handoff/outbox/$$0" /tmp/t --mode 0600 && cat /tmp/t' "$$name" >"$$tmp"); then \
			install -d -m 0700 $(FILLER_HOME_DIR)/trash/$$ts-filler-take-failed; mv "$$tmp" $(FILLER_HOME_DIR)/trash/$$ts-filler-take-failed/; \
			echo "$@: $$name refused (see above)" >&2; exit 1; fi; \
		if [ -e "$$dst" ] && ! cmp -s "$$tmp" "$$dst"; then install -d -m 0700 "$$dir/old-$$ts"; mv "$$dst" "$$dir/old-$$ts/"; fi; \
		mv -T "$$tmp" "$$dst"; \
		$(FILLER_ADMIN_RUN) -T --entrypoint sh filler-admin -euc 'mkdir -p -m 0700 "/filler/trash/$$1-taken"; mv "/filler/outbox/$$0" "/filler/trash/$$1-taken/"' "$$name" "$$ts"; \
		echo "$@: $$name -> $$dst"; n=$$((n+1)); \
	done; \
	if [ $$n -eq 0 ]; then echo "$@: nothing waiting in outbox/"; \
	else echo "$@: restart the bridge to use a new bridge token (the vault tools read theirs on every call)"; fi

# prep's side the other way: the filler's copy of the browser controller token,
# through stdin into inbox/ (1990:1990 3730: the operator container may add, not
# list), as a file of uid 1989's; filler-controller-token-take (uid 1990) takes it.
filler-controller-token-give:
	$(FILLER_AS_OPERATOR)
	@test -s $(FILLER_HOME_DIR)/secrets/api-token || { echo "$@: $(FILLER_HOME_DIR)/secrets/api-token missing; run make browser-init first" >&2; exit 1; }
	@$(FILLER_OPERATOR_RUN) 'umask 022; t=$$(mktemp /handoff/inbox/.controller-token.XXXXXX); cat >"$$t"; chmod 0640 "$$t"; mv "$$t" /handoff/inbox/controller-token' \
		<$(FILLER_HOME_DIR)/secrets/api-token
	@echo "$@: dropped; make filler-controller-token-take takes it (make vault-tokens does both)"

filler-test:
	cd $(FILLER_DIR) && node --test --test-timeout=30000 test/*.test.mjs

filler-smoke:
	cd $(FILLER_DIR) && timeout 120 node test/smoke.mjs

vault-mcp-test:
	cd $(VAULT_MCP_DIR) && node --test --test-timeout=30000 test/*.test.mjs
