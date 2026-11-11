# The secret filler (browser-stack/browser/filler): types vault secrets into the
# agent's browser by name, so the agent never sees a value. It runs on bare
# metal as its own account, happy-filler (uid 1990), as a systemd user unit of
# that account (systemd/happy-filler.service), from a reviewed release under
# /srv/happy-filler/current, on 127.0.0.1:6091. Vaultwarden is the standalone
# container on 127.0.0.1:8222 (selfhost/vault.mk).
# Included from browser-stack/Makefile and selfhost/Makefile.
# See browser-stack/browser/filler/README.md.
#
# Once, as prep, with sudo (the only filler target that ever needs root):
#   make filler-account-setup COMMIT=<sha>   create happy-filler (asks for your sudo password, then
#                                            happy-filler's new password twice), enable linger, stop
#                                            an old docker filler, chown /srv/happy-filler to it and
#                                            make outbox/ and inbox/. It installs and starts nothing.
#
# Admin targets: as happy-filler, no sudo. `su - happy-filler`, then
# `make -C /home/prep/happy/selfhost filler-<command>` (or `filler-admin <command>`;
# both run the installed release's scripts/filler-admin.sh, and filler-install
# runs scripts/filler-install.sh as it is in COMMIT). As any other account they
# print the su command and fail.
#   make filler-install COMMIT=  deploy a reviewed commit to /srv/happy-filler/releases/<sha>
#                                (npm ci from the lockfile), switch current, upgrade and check
#                                the policy, install and enable the unit, link ~/bin/filler-admin,
#                                restart and wait for /healthz
#   make filler-up / filler-down / filler-restart / filler-lock / filler-logs
#                                filler-down and filler-lock stop the unit (its keys leave memory)
#                                and disable it at boot until filler-up
#   make filler-token-issue NAME=bridge-client|vault-client [FILLER_ROTATE=1]
#                                a new client token: hash kept, plaintext once to outbox/<NAME>-token
#   make filler-controller-token-take   inbox/controller-token -> secrets/controller-token (0400)
#   make filler-init             directories and an empty policy (fresh install)
#   make filler-enroll [BACKEND=shared] [VAULT_URL=...]
#                                (terminal) enroll with the agent's vault account; shared writes
#                                secrets/, another backend secrets/<name>/
#   make filler-seed-policy      seed an empty policy with default_client "agent"
#   make filler-policy-edit      (terminal) back up, edit a copy, validate, swap it in
#   make filler-policy-upgrade   once per step: an older policy gets pipe_targets + manage, backends
#   make filler-check-policy     validate policy.json with the installed release
#   make filler-items            the agent account's logins: name, item id, https hosts (no values)
#   make filler-setup COMMIT=    a fresh install in one go: init, install, tokens, seed-policy, enroll, restart
#   make filler-outbox-clear     move tokens prep has not taken to /srv/happy-filler/trash
#
# As prep (read-only, or prep's side of a token handoff):
#   make filler-status           release, unit process, 127.0.0.1-only bind on 6091, /healthz, tokens
#   make filler-audit            the newest audit lines (FILLER_AUDIT_LINES=50)
#   make filler-token-take       outbox tokens -> prep's secrets dirs (0600)
#   make filler-controller-token-give   the browser controller token -> /srv/happy-filler/inbox
#   make filler-test             unit tests (node:test)
#   make filler-smoke            canary end-to-end: a separate filler + fake vault + fake page, leak sweep
#   make vault-mcp-test          unit tests of the vault tools' MCP server (browser-stack/vault-mcp)

FILLER_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/browser/filler
FILLER_REPO := $(abspath $(FILLER_DIR)/../../..)
FILLER_ROOT ?= /srv/happy-filler
FILLER_ACCOUNT := happy-filler
FILLER_UID ?= 1990
FILLER_ADMIN := $(FILLER_ROOT)/current/app/scripts/filler-admin.sh
FILLER_URL ?= http://127.0.0.1:6091
FILLER_AUDIT_LINES ?= 50
FILLER_HOME_DIR := $(or $(BROWSER_STACK_HOME),$(HAPPY_BROWSER_HOME),$(HOME)/.local/share/happy-browser)
# Where vault-mcp (browser-stack/vault-mcp) finds its token for the filler's /v1/vault/* routes.
VAULT_MCP_HOME_DIR := $(or $(BROWSER_VAULT_MCP_HOME),$(HAPPY_VAULT_MCP_HOME),$(HOME)/.local/share/happy-vault-mcp)
VAULT_MCP_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/vault-mcp
# The filler's earlier containers; filler-status warns if one still runs.
FILLER_OLD_CONTAINERS := happy-filler-filler-1 happy-vault-filler-1
COMMIT ?=
NAME ?=
BACKEND ?=

# First line of every admin recipe: only happy-filler gets past it.
FILLER_AS_ACCOUNT = @if [ "$$(id -un)" != "$(FILLER_ACCOUNT)" ]; then \
	echo "$@: run as $(FILLER_ACCOUNT), not $$(id -un) (no sudo):" >&2; \
	echo "  su - $(FILLER_ACCOUNT)" >&2; \
	echo "  make -C $(FILLER_REPO)/selfhost $@$(if $(COMMIT), COMMIT=$(COMMIT))$(if $(NAME), NAME=$(NAME))$(if $(BACKEND), BACKEND=$(BACKEND))" >&2; \
	exit 1; fi
FILLER_NEED_ADMIN = @test -f $(FILLER_ADMIN) || { echo "$@: the installed release has no scripts/filler-admin.sh; first: make filler-install COMMIT=<sha>" >&2; exit 1; }
# Prep-side targets refuse happy-filler and root (they work on prep's own files).
FILLER_AS_OPERATOR = @if [ "$$(id -un)" = "$(FILLER_ACCOUNT)" ] || [ "$$(id -u)" = 0 ]; then echo "$@: run as your own account (prep), not $$(id -un)" >&2; exit 1; fi

FILLER_ADMIN_TARGETS := filler-install filler-setup filler-init filler-enroll filler-seed-policy filler-policy-edit \
	filler-policy-upgrade filler-check-policy filler-up filler-down filler-restart filler-lock filler-logs \
	filler-items filler-outbox-clear filler-token-issue filler-controller-token-take

.PHONY: filler-account-setup $(FILLER_ADMIN_TARGETS) filler-status filler-audit filler-token-take \
	filler-controller-token-give filler-test filler-smoke vault-mcp-test

filler-account-setup:
	$(FILLER_AS_OPERATOR)
	@test -n "$(COMMIT)" || { echo "usage: make filler-account-setup COMMIT=<sha> (the commit you reviewed)" >&2; exit 1; }
	@echo "== filler-account-setup: the one filler step that needs root. It asks for your sudo password,"
	@echo "   then for a new password for $(FILLER_ACCOUNT), twice. It runs the script as it is in $(COMMIT)."
	@install -d -m 0700 $(FILLER_HOME_DIR) $(FILLER_HOME_DIR)/trash
	@s=$$(mktemp $(FILLER_HOME_DIR)/trash/account-setup.XXXXXX.sh) \
		&& git -C $(FILLER_REPO) cat-file blob "$(COMMIT):browser-stack/browser/filler/scripts/filler-account-setup.sh" >$$s \
		&& sudo FILLER_REPO="$(FILLER_REPO)" FILLER_NEW_PASSWORD="$(FILLER_NEW_PASSWORD)" bash $$s

# The install script (or, for filler-setup, the admin script) of COMMIT itself,
# taken from happy-filler's own mirror of the repo (a fetch re-hashes every
# object, so it is the reviewed blob): the first install has no installed copy to run.
filler-install filler-setup:
	$(FILLER_AS_ACCOUNT)
	@test -n "$(COMMIT)" || { echo "usage: make $@ COMMIT=<sha> (the commit you reviewed)" >&2; exit 1; }
	@set -e; m=$$HOME/src.git; [ -d $$m ] || git init -q --bare $$m; \
	for d in "$(FILLER_REPO)" "$(FILLER_REPO)/.git"; do \
		git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$$d" || git config --global --add safe.directory "$$d"; done; \
	git --no-pager -c "safe.directory=$(FILLER_REPO)" -c "safe.directory=$(FILLER_REPO)/.git" --git-dir=$$m fetch -q --no-tags "file://$(FILLER_REPO)" '+refs/heads/*:refs/prep/*'; \
	install -d -m 0700 $$HOME/trash; s=$$(mktemp $$HOME/trash/$@.XXXXXX.sh); \
	f=$(if $(filter filler-install,$@),filler-install.sh,filler-admin.sh); \
	git --no-pager --git-dir=$$m cat-file blob "$(COMMIT):browser-stack/browser/filler/scripts/$$f" >$$s 2>/dev/null \
		|| { echo "$@: $(COMMIT) has no browser-stack/browser/filler/scripts/$$f" >&2; exit 1; }; \
	if [ $@ = filler-install ]; then FILLER_REPO="$(FILLER_REPO)" bash $$s COMMIT="$(COMMIT)"; \
	else FILLER_REPO="$(FILLER_REPO)" bash $$s setup COMMIT="$(COMMIT)" $(if $(VAULT_AGENT_EMAIL),FILLER_AGENT_EMAIL="$(VAULT_AGENT_EMAIL)"); fi

filler-init filler-policy-edit filler-policy-upgrade filler-check-policy filler-up filler-down filler-restart filler-lock filler-logs filler-items filler-outbox-clear filler-controller-token-take:
	$(FILLER_AS_ACCOUNT)
	$(FILLER_NEED_ADMIN)
	@bash $(FILLER_ADMIN) $(patsubst filler-%,%,$@)

filler-enroll:
	$(FILLER_AS_ACCOUNT)
	$(FILLER_NEED_ADMIN)
	@bash $(FILLER_ADMIN) enroll $(if $(BACKEND),BACKEND="$(BACKEND)") $(if $(VAULT_URL),VAULT_URL="$(VAULT_URL)") \
		$(if $(VAULT_AGENT_EMAIL),FILLER_AGENT_EMAIL="$(VAULT_AGENT_EMAIL)")

filler-seed-policy:
	$(FILLER_AS_ACCOUNT)
	$(FILLER_NEED_ADMIN)
	@bash $(FILLER_ADMIN) seed-policy FILLER_DEFAULT_CLIENT="$(or $(FILLER_DEFAULT_CLIENT),agent)"

filler-token-issue:
	$(FILLER_AS_ACCOUNT)
	$(FILLER_NEED_ADMIN)
	@bash $(FILLER_ADMIN) token-issue NAME="$(NAME)" $(if $(FILLER_ROTATE),FILLER_ROTATE="$(FILLER_ROTATE)")

filler-status:
	@echo "== secret filler ($(FILLER_ACCOUNT), systemd user unit happy-filler.service)"
	@if [ -e $(FILLER_ROOT)/current/COMMIT ]; then echo "release: $$(cat $(FILLER_ROOT)/current/COMMIT) ($$(readlink $(FILLER_ROOT)/current))"; else echo "release: none installed"; fi
	@if [ -e $(FILLER_ROOT)/current/app/scripts/filler-admin.sh ]; then :; elif [ -e $(FILLER_ROOT)/current/app ]; then \
		echo "note: this release has no scripts/filler-admin.sh; as $(FILLER_ACCOUNT): make -C $(FILLER_REPO)/selfhost filler-install COMMIT=<sha>"; fi
	@printf "process: "; ps -o uid=,pid=,etime=,args= -C node 2>/dev/null | awk '$$1=="$(FILLER_UID)"{print "$(FILLER_ACCOUNT)", $$2, "up", $$3; f=1} END{if(!f) print "not running"}'
	@for c in $(FILLER_OLD_CONTAINERS); do \
		if [ "$$(docker container inspect -f '{{.State.Running}}' $$c 2>/dev/null)" = true ]; then echo "note: the old docker filler $$c is running"; fi; done
	@echo "listening on 6091 (expect 127.0.0.1 only):"
	@ss -ltnH | awk '{print $$4}' | grep -E ':6091$$' | sort -u || echo "  (none)"
	@if ss -ltnH | awk '{print $$4}' | grep -E ':6091$$' | grep -qvE '^127\.0\.0\.1:'; then \
		echo "WARNING: 6091 is bound beyond 127.0.0.1"; exit 1; fi
	@printf "healthz: "; curl -fs --max-time 5 $(FILLER_URL)/healthz || printf "unreachable"; echo
	@printf "bridge client token: "; test -s $(FILLER_HOME_DIR)/secrets/filler-client-token && echo present || echo "absent (bridge secret tools off)"
	@printf "vault-mcp token: "; test -s $(VAULT_MCP_HOME_DIR)/secrets/vault-client-token && echo present || echo "absent (vault tools off)"
	@if [ -r $(FILLER_ROOT)/outbox ] && ls -A $(FILLER_ROOT)/outbox 2>/dev/null | grep -qvE '^\.'; then \
		echo "tokens waiting in $(FILLER_ROOT)/outbox: $$(ls $(FILLER_ROOT)/outbox | tr '\n' ' ')(make filler-token-take)"; fi

filler-audit:
	@ls -1 $(FILLER_ROOT)/audit/*.jsonl >/dev/null 2>&1 || { echo "no audit yet"; exit 0; }
	@tail -q -n $(FILLER_AUDIT_LINES) $$(ls -1 $(FILLER_ROOT)/audit/*.jsonl | sort | tail -n 2) | tail -n $(FILLER_AUDIT_LINES)

# prep's side of a client-token handoff. filler-token-issue leaves each new
# token in outbox/ (happy-filler:prep 2770, the file happy-filler's own, 0640).
# A file prep does not own cannot be chmod-ed by prep, so the token is copied
# (scripts/handoff-copy.mjs: a regular file, one link, token-shaped) into a new
# file of prep's (0600; an old different one goes to old-<ts>/), and the outbox
# file itself is moved to $(FILLER_HOME_DIR)/trash/<ts>-filler-outbox/.
filler-token-take:
	$(FILLER_AS_OPERATOR)
	@test -d $(FILLER_ROOT)/outbox || { echo "$@: no $(FILLER_ROOT)/outbox; run make filler-account-setup COMMIT=<sha> first" >&2; exit 1; }
	@set -e; ts=$$(date -u +%Y%m%dT%H%M%SZ); n=0; \
	for pair in bridge-client-token:$(FILLER_HOME_DIR)/secrets/filler-client-token vault-client-token:$(VAULT_MCP_HOME_DIR)/secrets/vault-client-token; do \
		name=$${pair%%:*}; dst=$${pair#*:}; dir=$${dst%/*}; src=$(FILLER_ROOT)/outbox/$$name; \
		[ -e "$$src" ] || [ -L "$$src" ] || continue; \
		install -d -m 0700 "$$dir"; tmp="$$dir/.$$name.take-$$ts"; \
		node $(FILLER_DIR)/scripts/handoff-copy.mjs "$$src" "$$tmp" --mode 0600; \
		if [ -e "$$dst" ] && ! cmp -s "$$tmp" "$$dst"; then install -d -m 0700 "$$dir/old-$$ts"; mv "$$dst" "$$dir/old-$$ts/"; fi; \
		mv -T "$$tmp" "$$dst"; \
		install -d -m 0700 $(FILLER_HOME_DIR)/trash $(FILLER_HOME_DIR)/trash/$$ts-filler-outbox; \
		mv -T "$$src" $(FILLER_HOME_DIR)/trash/$$ts-filler-outbox/$$name; \
		echo "$@: $$name -> $$dst"; n=$$((n+1)); \
	done; \
	if [ $$n -eq 0 ]; then echo "$@: nothing waiting in $(FILLER_ROOT)/outbox"; \
	else echo "$@: restart the bridge to use a new bridge token (the vault tools read theirs on every call)"; fi

# prep's side the other way: the filler's copy of the browser controller token.
# inbox/ is happy-filler:prep 3730 (prep may add, not list); filler-controller-token-take takes it.
filler-controller-token-give:
	$(FILLER_AS_OPERATOR)
	@test -s $(FILLER_HOME_DIR)/secrets/api-token || { echo "$@: $(FILLER_HOME_DIR)/secrets/api-token missing; run make browser-init first" >&2; exit 1; }
	@test -d $(FILLER_ROOT)/inbox || { echo "$@: no $(FILLER_ROOT)/inbox; run make filler-account-setup COMMIT=<sha> first" >&2; exit 1; }
	@t=$$(mktemp $(FILLER_ROOT)/inbox/.controller-token.XXXXXX) && cp $(FILLER_HOME_DIR)/secrets/api-token $$t \
		&& chmod 0644 $$t && mv -T $$t $(FILLER_ROOT)/inbox/controller-token
	@echo "$@: dropped; now su - $(FILLER_ACCOUNT), make -C $(FILLER_REPO)/selfhost filler-controller-token-take, then filler-restart"

filler-test:
	cd $(FILLER_DIR) && node --test --test-timeout=30000 test/*.test.mjs

filler-smoke:
	cd $(FILLER_DIR) && timeout 120 node test/smoke.mjs

vault-mcp-test:
	cd $(VAULT_MCP_DIR) && node --test --test-timeout=30000 test/*.test.mjs
