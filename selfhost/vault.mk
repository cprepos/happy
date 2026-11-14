# The vault: Vaultwarden, the self-hosted Bitwarden server for every device
# (phone, laptops, browser extensions). It runs as one standalone container in
# prep's Docker, `vaultwarden` (label happy.standalone=vaultwarden, outside
# every compose project, restart unless-stopped, 127.0.0.1:8222), with its
# data in the named volumes vaultwarden-data and vaultwarden-config
# (vault/scripts/vaultwarden.sh). Nothing here needs sudo. No browser-* target
# touches it. The browser agent's secret filler, which reads the vault, runs on
# bare metal as happy-filler (browser-stack/filler.mk).
# Host settings (domain, agent email, uids, LAN addresses) are in vault/.env
# (copy vault/.env.example).
# Included from selfhost/Makefile via `-include vault.mk`. See selfhost/vault/README.md.
#
#   make vault-up             start Vaultwarden; create it first if there is none (a fresh install
#                             also needs VAULT_OWNER_EMAIL=<your vault email>, once, for its env file).
#                             A running container is left alone. Refuses a vaultwarden container
#                             that is not this one (no label).
#   make vault-down           stop it (container and volumes kept)
#   make vault-logs
#   make vault-status         the container, 127.0.0.1-only bind, local and public /alive, public /admin
#                             = 404, env keys set/unset, then filler-status
#   make vault-admin-on       set an admin password (asked on the terminal; only its hash is kept),
#                             then restart Vaultwarden
#   make vault-admin-off      remove it, which disables /admin, then restart Vaultwarden
#   make vault-caddy-apply    add $(VAULT_DOMAIN) to the host's Caddy (backup, validate, reload)
#   make stack-up / stack-down  Vaultwarden and the browser stack together (selfhost/Makefile)
#
# The filler's enrollment and tokens are filler targets: make filler-enroll, filler-token-issue,
# filler-token-take (browser-stack/filler.mk).
#
# Backups (vault/scripts/vault-backup.sh; selfhost/vault/README.md, Backups), from prep's cron:
#   make vault-backup         vault and filler tarballs into /girth/backup/vault (ZFS snapshot
#                             after each run), then the mirror /mnt/ai-data/backups/happy-vault
#   make vault-backup-check   restore the newest tarballs into throwaway containers and count
#   make vault-backup-status  newest tarball per location and its age (STALE past 26 h)
#   make vault-restore TARBALL=vault-<ts>.tar.gz|/path/to/it   stops Vaultwarden while it runs
#   make vault-backup-cron    add the nightly backup and the weekly check to prep's crontab,
#                             each line only if it is missing

VAULT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/vault
# Host settings: plain KEY=value lines, read here (and by browser-stack/filler.mk through the exports).
-include $(VAULT_DIR)/.env
VAULT_ENV_VARS := VAULT_DOMAIN CADDY_AFTER_SITE CADDYFILE VAULT_AGENT_EMAIL FILLER_ROOT VAULT_UID FILLER_UID FILLER_GID
export $(VAULT_ENV_VARS)
# The LAN addresses, for the agent gateway and MCP registration (browser-stack/gateway, scripts/mcp-register.py).
ifneq ($(LAN_IP),)
export BROWSER_STACK_LAN_BIND ?= $(LAN_IP)
endif
ifneq ($(LAN_CLIENTS),)
export BROWSER_STACK_MACS ?= $(LAN_CLIENTS)
endif
VAULT_URL ?= http://127.0.0.1:8222
VAULT_SITE ?= $(VAULT_DOMAIN)
VAULT_OWNER_EMAIL ?=
export VAULT_OWNER_EMAIL
VAULTWARDEN := bash $(VAULT_DIR)/scripts/vaultwarden.sh

.PHONY: vault-up vault-down vault-logs vault-status vault-admin-on vault-admin-off vault-caddy-apply \
	vault-backup vault-backup-check vault-backup-status vault-restore vault-backup-cron

VAULT_NEED_ENV = @test -f $(VAULT_DIR)/.env || { echo "$@: no $(VAULT_DIR)/.env; cp $(VAULT_DIR)/.env.example $(VAULT_DIR)/.env and fill it in" >&2; exit 1; }

vault-up:
	$(VAULT_NEED_ENV)
	@$(VAULTWARDEN) up

vault-down:
	@$(VAULTWARDEN) down

vault-logs:
	@$(VAULTWARDEN) logs

vault-status:
	@echo "== vault (standalone container vaultwarden)"
	@$(VAULTWARDEN) status
	@echo "listening on 8222 (expect 127.0.0.1 only):"
	@ss -ltnH | awk '{print $$4}' | grep -E ':8222$$' | sort -u || echo "  (none)"
	@if ss -ltnH | awk '{print $$4}' | grep -E ':8222$$' | grep -qvE '^127\.0\.0\.1:'; then \
		echo "WARNING: 8222 is bound beyond 127.0.0.1"; exit 1; fi
	@printf "local  /alive : "; curl -fs --max-time 5 -o /dev/null -w '%{http_code}' $(VAULT_URL)/alive || printf " unreachable"; echo
	@printf "public /alive : "; curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://$(VAULT_SITE)/alive || printf " unreachable"; echo
	@printf "public /admin : "; curl -s --max-time 8 -o /dev/null -w '%{http_code} (expect 404)' https://$(VAULT_SITE)/admin || printf " unreachable"; echo
	@$(MAKE) --no-print-directory filler-status

vault-admin-on:
	@bash $(VAULT_DIR)/scripts/vault-admin.sh on

vault-admin-off:
	@bash $(VAULT_DIR)/scripts/vault-admin.sh off

vault-caddy-apply:
	@bash $(VAULT_DIR)/scripts/vault-caddy-apply.sh

VAULT_BACKUP := bash $(VAULT_DIR)/scripts/vault-backup.sh
VAULT_CRON_BACKUP := 15 4 * * *  make -C /home/prep/happy/selfhost vault-backup >> ~/.local/state/happy/vault-backup.log 2>&1
VAULT_CRON_CHECK := 45 4 * * 0  make -C /home/prep/happy/selfhost vault-backup-check >> ~/.local/state/happy/vault-backup.log 2>&1

vault-backup:
	@echo "== vault-backup $$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	@$(VAULT_BACKUP) backup

vault-backup-check:
	@echo "== vault-backup-check $$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	@$(VAULT_BACKUP) check

vault-backup-status:
	@$(VAULT_BACKUP) status

vault-restore:
	@test -n "$(TARBALL)" || { echo "usage: make vault-restore TARBALL=vault-<ts>.tar.gz|/path/to/vault-<ts>.tar.gz" >&2; exit 2; }
	@$(VAULT_BACKUP) restore '$(TARBALL)'

# Adds each line only if prep's crontab lacks it; every other line stays as it is. The crontab
# as it was goes to ~/.local/state/happy/crontab-before-<ts> first.
vault-backup-cron:
	@mkdir -p $(HOME)/.local/state/happy
	@cur="$$(crontab -l 2>/dev/null || true)"; add=""; \
	for l in '$(VAULT_CRON_BACKUP)' '$(VAULT_CRON_CHECK)'; do \
		if grep -qxF -- "$$l" <<<"$$cur"; then echo "vault-backup-cron: present: $$l"; \
		else add="$$add$$l"$$'\n'; echo "vault-backup-cron: adding: $$l"; fi; \
	done; \
	if [ -n "$$add" ]; then \
		ts=$$(date -u +%Y%m%dT%H%M%SZ); printf '%s\n' "$$cur" > $(HOME)/.local/state/happy/crontab-before-$$ts; \
		{ printf '%s\n' "$$cur"; printf '%s' "$$add"; } | crontab - && echo "vault-backup-cron: installed (previous crontab in ~/.local/state/happy/crontab-before-$$ts)"; \
	fi

