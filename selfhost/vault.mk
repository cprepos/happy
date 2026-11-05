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
#   make vault-backup         versioned tarball in /srv/happy-vault/backups (newest 30 kept there)
#   make vault-restore-check  restore the newest backup in a throwaway container and count what is in it
#   make vault-backup-timer   install + enable the nightly systemd user timer that runs vault-backup

VAULT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/vault
VAULT_COMPOSE := docker compose -p happy-vault -f $(VAULT_DIR)/compose.vault.yml
VAULT_URL ?= http://127.0.0.1:8222
VAULT_SITE ?= vault.girthbass.duckdns.org
VAULT_OWNER_EMAIL ?=
VAULT_SYSTEMD := $(HOME)/.config/systemd/user

.PHONY: vault-init vault-up vault-down vault-logs vault-status vault-admin-on vault-admin-off \
	vault-caddy-apply vault-backup vault-restore-check vault-backup-timer

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
	@printf "backup timer  : "; systemctl --user is-active happy-vault-backup.timer 2>/dev/null || true
	@printf "newest backup : "; docker run --rm --network none -u 1991:1991 -v /srv/happy-vault/backups:/b:ro --entrypoint sh \
		$$(awk '/^ *image: vaultwarden\/server:/{print $$2; exit}' $(VAULT_DIR)/compose.vault.yml) \
		-c 'ls -1 /b/vault-*.tar.gz 2>/dev/null | sort | tail -n1 | xargs -r basename; ls /b/vault-*.tar.gz >/dev/null 2>&1 || echo none' 2>/dev/null || echo "unknown"

vault-admin-on:
	sudo bash $(VAULT_DIR)/scripts/vault-admin.sh on

vault-admin-off:
	sudo bash $(VAULT_DIR)/scripts/vault-admin.sh off

vault-caddy-apply:
	@bash $(VAULT_DIR)/scripts/vault-caddy-apply.sh

vault-backup:
	@bash $(VAULT_DIR)/scripts/vault-backup.sh backup

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
