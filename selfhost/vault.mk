# Vaultwarden, the self-hosted Bitwarden server for every device (phone,
# laptops, browser extensions) and for the browser agent's secret filler.
# Its own compose project (happy-vault): no browser-* target touches it.
# Included from selfhost/Makefile via `-include vault.mk`. See selfhost/vault/README.md.
#
#   make vault-init           (sudo, once) /srv/happy-vault, its env file; VAULT_OWNER_EMAIL=<your vault email>
#   make vault-up / vault-down / vault-logs
#   make vault-status         container health, 127.0.0.1-only bind, /alive, Caddy site, last backup
#   make vault-admin-on       (sudo) set an admin password (asked on the terminal; only its hash is kept)
#   make vault-admin-off      (sudo) remove it, which disables /admin
#   make vault-caddy-apply    add vault.girthbass.duckdns.org to Caddy (backup, validate, reload)
#   make vault-backup         versioned tarball in /srv/happy-vault/backups (newest 30 kept there),
#                             then copied to every mirror (VAULT_BACKUP_MIRRORS) + a ZFS snapshot
#   make vault-backup-mirror  copy any tarball a mirror is missing (no new backup)
#   make vault-restore-check  restore the newest backup of every location in a throwaway container,
#                             count what is in it, check the sha256 matches across locations
#   make vault-backup-timer   install + enable the nightly systemd user timer that runs vault-backup
#   make vault-backup-setup   print (never run) the one-time sudo commands: mirror dirs, ZFS
#                             delegation, the root timer for the filler state + env file backup

VAULT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/vault
VAULT_COMPOSE := docker compose -p happy-vault -f $(VAULT_DIR)/compose.vault.yml
VAULT_URL ?= http://127.0.0.1:8222
VAULT_SITE ?= vault.girthbass.duckdns.org
VAULT_OWNER_EMAIL ?=
VAULT_SYSTEMD := $(HOME)/.config/systemd/user
VAULT_BACKUP_MIRRORS ?= /girth/backup/vault /mnt/ai-data/backups/happy-vault
export VAULT_BACKUP_MIRRORS

.PHONY: vault-init vault-up vault-down vault-logs vault-status vault-admin-on vault-admin-off \
	vault-caddy-apply vault-backup vault-backup-mirror vault-restore-check vault-backup-timer vault-backup-setup

vault-init:
	sudo VAULT_OWNER_EMAIL="$(VAULT_OWNER_EMAIL)" bash $(VAULT_DIR)/scripts/vault-init.sh

vault-up:
	@test -f /srv/happy-vault/vaultwarden.env || { echo "run make vault-init first"; exit 1; }
	$(VAULT_COMPOSE) up -d --wait

vault-down:
	$(VAULT_COMPOSE) down

vault-logs:
	$(VAULT_COMPOSE) logs -f --tail=200

vault-status:
	@echo "== vault (happy-vault)"
	@$(VAULT_COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
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
		'f=/etc/vaultwarden.env; test -r $$f || { echo "not readable in the container"; exit 0; }; \
		for k in ORG_CREATION_USERS ADMIN_TOKEN; do grep -qE "^$$k=.+" $$f && printf "%s set  " $$k || printf "%s unset  " $$k; done; echo' \
		2>/dev/null || echo "container not running"
	@printf "backup timer  : "; systemctl --user is-active happy-vault-backup.timer 2>/dev/null || true
	@echo "newest backup per location (STALE = older than 26h):"
	@bash $(VAULT_DIR)/scripts/vault-backup.sh status || echo "  unknown"
	@printf "secrets timer : "; systemctl is-active happy-vault-secrets-backup.timer 2>/dev/null || echo "  (install: make vault-backup-setup)"
	@printf "secrets last  : "; systemctl show happy-vault-secrets-backup.service -p Result -p ExecMainExitTimestamp --value 2>/dev/null | paste -sd' ' -

vault-admin-on:
	sudo bash $(VAULT_DIR)/scripts/vault-admin.sh on

vault-admin-off:
	sudo bash $(VAULT_DIR)/scripts/vault-admin.sh off

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
