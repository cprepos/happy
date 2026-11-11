# The vault: Vaultwarden, the self-hosted Bitwarden server for every device
# (phone, laptops, browser extensions), and the browser agent's secret filler,
# both in one compose project (happy-vault, vault/compose.vault.yml). No
# browser-* target touches it. Its data is in named Docker volumes
# (happy-vault-data, -config, -backups, happy-filler); nothing here needs sudo.
# Host settings (domain, agent email, uids, LAN addresses) are in vault/.env
# (copy vault/.env.example).
# Included from selfhost/Makefile via `-include vault.mk`. See selfhost/vault/README.md.
#
# A fresh install, in order:
#   make vault-init           (once) the volumes, the env file, the filler's tree and its empty
#                             policy; VAULT_OWNER_EMAIL=<your vault email>
#   make vault-up             Vaultwarden and the filler (builds the filler image)
#   make vault-tokens         client tokens for vault-mcp and the bridge, and the browser controller
#                             token for the filler (each only once; ROTATE=1 NAME=bridge-client|vault-client
#                             replaces one), then restarts the filler
#   make filler-seed-policy   a default policy (or make filler-policy-edit)
#   make vault-enroll BACKEND=shared   (terminal) enroll the filler with the agent's vault account
#
#   make stack-up / stack-down  the vault and the browser stack together (selfhost/Makefile)
#   make vault-up / vault-down / vault-logs
#   make vault-status         containers, 127.0.0.1-only binds, /alive, Caddy site, filler unlocked, last backup
#   make vault-admin-on       set an admin password (asked on the terminal; only its hash is kept)
#   make vault-admin-off      remove it, which disables /admin
#   make vault-caddy-apply    add $(VAULT_DOMAIN) to the host's Caddy (backup, validate, reload)
#   make vault-backup         versioned tarball in the happy-vault-backups volume (newest 30 kept there),
#                             then copied to every mirror (VAULT_BACKUP_MIRRORS) + a ZFS snapshot
#   make vault-backup-mirror  copy any tarball a mirror is missing (no new backup)
#   make vault-restore-check  restore the newest backup of every location in a throwaway container,
#                             count what is in it, check the sha256 matches across locations
#   make vault-backup-timer   install + enable the nightly systemd user timer that runs vault-backup
#   make vault-backup-setup   print (never run) the one-time sudo commands: mirror dirs, ZFS
#                             delegation, the root timer for the filler state + env file backup

VAULT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/vault
# Host settings: plain KEY=value lines, read by compose (from vault/) and here.
-include $(VAULT_DIR)/.env
VAULT_ENV_VARS := VAULT_DOMAIN CADDY_AFTER_SITE CADDYFILE VAULT_AGENT_EMAIL VAULT_ROOT FILLER_ROOT VAULT_UID FILLER_UID FILLER_GID
export $(VAULT_ENV_VARS)
# The LAN addresses, for the agent gateway and MCP registration (browser-stack/gateway, scripts/mcp-register.py).
ifneq ($(LAN_IP),)
export BROWSER_STACK_LAN_BIND ?= $(LAN_IP)
endif
ifneq ($(LAN_CLIENTS),)
export BROWSER_STACK_MACS ?= $(LAN_CLIENTS)
endif
VAULT_COMPOSE := docker compose -p happy-vault -f $(VAULT_DIR)/compose.vault.yml
VAULT_URL ?= http://127.0.0.1:8222
VAULT_SITE ?= $(VAULT_DOMAIN)
BACKEND ?= shared
VAULT_OWNER_EMAIL ?=
VAULT_SYSTEMD := $(HOME)/.config/systemd/user
VAULT_BACKUP_MIRRORS ?= /girth/backup/vault /mnt/ai-data/backups/happy-vault
export VAULT_BACKUP_MIRRORS

.PHONY: vault-init vault-up vault-down vault-logs vault-status vault-enroll vault-tokens vault-admin-on vault-admin-off \
	vault-caddy-apply vault-backup vault-backup-mirror vault-restore-check vault-backup-timer vault-backup-setup

VAULT_NEED_ENV = @test -f $(VAULT_DIR)/.env || { echo "$@: no $(VAULT_DIR)/.env; cp $(VAULT_DIR)/.env.example $(VAULT_DIR)/.env and fill it in" >&2; exit 1; }

vault-init:
	$(VAULT_NEED_ENV)
	VAULT_OWNER_EMAIL="$(VAULT_OWNER_EMAIL)" bash $(VAULT_DIR)/scripts/vault-init.sh
	@$(MAKE) --no-print-directory filler-build
	$(FILLER_ADMIN_RUN) -T filler-admin init

vault-up:
	$(VAULT_NEED_ENV)
	@docker volume inspect happy-vault-config happy-filler >/dev/null 2>&1 || { echo "$@: no vault volumes; run make vault-init first" >&2; exit 1; }
	$(FILLER_PORT_GUARD)
	$(VAULT_COMPOSE) up -d --build --wait

# One backend for now: the shared Vaultwarden (more come with the policy's backends section).
vault-enroll:
	@test "$(BACKEND)" = shared || { echo "$@: BACKEND=shared is the only backend so far" >&2; exit 1; }
	$(FILLER_ADMIN_RUN) filler-admin enroll
	$(VAULT_COMPOSE) restart filler

# The tokens, both ways, with no account line to hand them across: the filler
# (in its container) writes each client token it issues to outbox/, and
# filler-token-take copies it into prep's secrets dirs (0600); the browser
# controller token goes the other way through inbox/. A token that exists is
# kept; ROTATE=1 NAME=bridge-client|vault-client issues that one again.
vault-tokens:
	$(FILLER_AS_OPERATOR)
	@set -e; names="$$($(FILLER_ADMIN_RUN) -T filler-admin tokens-missing)"; \
	if [ "$(ROTATE)" = 1 ]; then names="$(NAME)"; test -n "$$names" || { echo "$@: ROTATE=1 needs NAME=bridge-client|vault-client" >&2; exit 1; }; fi; \
	for n in $$names; do $(FILLER_ADMIN_RUN) -T filler-admin token-issue NAME=$$n $(if $(filter 1,$(ROTATE)),ROTATE=1); done
	@$(MAKE) --no-print-directory filler-token-take
	@$(MAKE) --no-print-directory filler-controller-token-give
	$(FILLER_ADMIN_RUN) -T filler-admin controller-token-take
	@if [ "$$(docker container inspect -f '{{.State.Running}}' happy-vault-filler-1 2>/dev/null)" = true ]; then \
		$(VAULT_COMPOSE) restart filler && $(MAKE) --no-print-directory filler-wait; fi

vault-down:
	$(VAULT_COMPOSE) down

vault-logs:
	$(VAULT_COMPOSE) logs -f --tail=200

vault-status:
	@echo "== vault (happy-vault)"
	@$(VAULT_COMPOSE) ps -a --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
	@echo "listening on 8222 (expect 127.0.0.1 only):"
	@ss -ltnH | awk '{print $$4}' | grep -E ':8222$$' | sort -u || echo "  (none)"
	@if ss -ltnH | awk '{print $$4}' | grep -E ':8222$$' | grep -qvE '^127\.0\.0\.1:'; then \
		echo "WARNING: 8222 is bound beyond 127.0.0.1"; exit 1; fi
	@printf "local  /alive : "; curl -fs --max-time 5 -o /dev/null -w '%{http_code}' $(VAULT_URL)/alive || printf " unreachable"; echo
	@printf "public /alive : "; curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://$(VAULT_SITE)/alive || printf " unreachable"; echo
	@printf "public /admin : "; curl -s --max-time 8 -o /dev/null -w '%{http_code} (expect 404)' https://$(VAULT_SITE)/admin || printf " unreachable"; echo
	@# Vaultwarden loads the env file into its own process (ENV_FILE), so
	@# docker exec printenv never shows these; read key names from the mount.
	@printf "env file      : "; docker exec happy-vault-vaultwarden-1 sh -c \
		'f=/etc/vaultwarden/vaultwarden.env; test -r $$f || { echo "not readable in the container"; exit 0; }; \
		for k in ORG_CREATION_USERS ADMIN_TOKEN; do grep -qE "^$$k=.+" $$f && printf "%s set  " $$k || printf "%s unset  " $$k; done; echo' \
		2>/dev/null || echo "container not running"
	@printf "backup timer  : "; systemctl --user is-active happy-vault-backup.timer 2>/dev/null || true
	@echo "newest backup per location (STALE = older than 26h):"
	@bash $(VAULT_DIR)/scripts/vault-backup.sh status || echo "  unknown"
	@if [ "$$(systemctl show happy-vault-secrets-backup.timer -p LoadState --value 2>/dev/null)" = loaded ]; then \
		printf "secrets timer : %s; last run: %s, %s\n" "$$(systemctl is-active happy-vault-secrets-backup.timer)" \
			"$$(systemctl show happy-vault-secrets-backup.service -p ExecMainExitTimestamp --value)" \
			"$$(systemctl show happy-vault-secrets-backup.service -p Result --value)"; \
	else echo "secrets timer : not installed (make vault-backup-setup)"; fi
	@$(MAKE) --no-print-directory filler-status

vault-admin-on:
	@bash $(VAULT_DIR)/scripts/vault-admin.sh on

vault-admin-off:
	@bash $(VAULT_DIR)/scripts/vault-admin.sh off

vault-caddy-apply:
	@bash $(VAULT_DIR)/scripts/vault-caddy-apply.sh

vault-backup:
	@bash $(VAULT_DIR)/scripts/vault-backup.sh backup

vault-backup-mirror:
	@bash $(VAULT_DIR)/scripts/vault-backup.sh mirror

vault-restore-check:
	@bash $(VAULT_DIR)/scripts/vault-backup.sh check

vault-backup-timer:
	@mkdir -p $(VAULT_SYSTEMD)
	@for u in happy-vault-backup.service happy-vault-backup.timer; do \
		if [ -e $(VAULT_SYSTEMD)/$$u ] && ! cmp -s $(VAULT_DIR)/systemd/$$u $(VAULT_SYSTEMD)/$$u; then \
			d=$(VAULT_SYSTEMD)/trash/$$(date +%Y%m%d_%H%M%S)_$$u; mkdir -p $$d && mv $(VAULT_SYSTEMD)/$$u $$d/; fi; \
		cp $(VAULT_DIR)/systemd/$$u $(VAULT_SYSTEMD)/$$u; done
	systemctl --user daemon-reload
	systemctl --user enable --now happy-vault-backup.timer
	@systemctl --user list-timers happy-vault-backup.timer --no-pager

# Prints the one-time root setup; nothing here runs sudo. Rerun the last block
# after vault-secrets-backup.sh or its units change in the repo.
vault-backup-setup:
	@echo "# 1. mirror dirs (uid 1991 like /srv/happy-vault/backups) and ZFS snapshot delegation"
	@echo "sudo zfs create -p -o compression=lz4 girth/backup/vault"
	@echo "sudo chown 1991:1991 /girth/backup/vault && sudo chmod 700 /girth/backup/vault"
	@echo "sudo mkdir -p /mnt/ai-data/backups/happy-vault"
	@echo "sudo chown 1991:1991 /mnt/ai-data/backups/happy-vault && sudo chmod 700 /mnt/ai-data/backups/happy-vault"
	@echo "sudo zfs allow -u $(USER) snapshot,mount girth/backup"
	@echo "# 2. root timer: filler state + vaultwarden.env into <mirror>/secrets/"
	@echo "sudo install -o root -g root -m 0755 $(VAULT_DIR)/scripts/vault-secrets-backup.sh /usr/local/sbin/happy-vault-secrets-backup"
	@echo "sudo install -o root -g root -m 0644 $(VAULT_DIR)/systemd/happy-vault-secrets-backup.service $(VAULT_DIR)/systemd/happy-vault-secrets-backup.timer /etc/systemd/system/"
	@echo "sudo systemctl daemon-reload"
	@echo "sudo systemctl enable --now happy-vault-secrets-backup.timer"
	@echo "sudo systemctl start happy-vault-secrets-backup.service   # first run now; check with: systemctl status happy-vault-secrets-backup.service"
