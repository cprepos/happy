# Self-hosted Happy: server + Postgres via Docker Compose.
# Run from this directory: `make up`, `make status`, `make logs`.

SHELL := /bin/bash
COMPOSE := docker compose --project-directory $(CURDIR) -f $(CURDIR)/docker-compose.yml --env-file $(CURDIR)/.env

.PHONY: help env build up down status logs migrate webapp-dir stack-up stack-down

help:
	@echo "Targets: env build up down status logs migrate"
	@echo "Stack:   stack-up stack-down (the vault with its filler, then the browser stack)"

# Create .env with random secrets if it does not exist yet (never overwrites).
env:
	@if [ -f .env ]; then echo ".env already exists, leaving it untouched"; else \
		cp .env.example .env && \
		sed -i "s/^HANDY_MASTER_SECRET=.*/HANDY_MASTER_SECRET=$$(openssl rand -hex 32)/" .env && \
		sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$$(openssl rand -hex 24)/" .env && \
		chmod 600 .env && echo "Wrote .env"; fi

webapp-dir:
	@mkdir -p webapp

build: env
	$(COMPOSE) build happy-server

up: env webapp-dir
	$(COMPOSE) up -d --build postgres happy-server

down:
	$(COMPOSE) down

status:
	$(COMPOSE) ps
	@echo
	@printf "local  /      : HTTP "; curl -sS -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:3005/ || echo "unreachable"; echo
	@printf "local  /health: "; curl -fsS --max-time 5 http://127.0.0.1:3005/health || echo "unreachable"; echo
	@echo
	@$(MAKE) --no-print-directory vault-status || echo "vault-status: FAILED"

logs:
	$(COMPOSE) logs -f --tail=200

# The browser stack (live browser, bridge, filler, vault MCP server, MCP registration) lives in
# ../browser-stack; its make fragments are included here so every browser-*, filler-*,
# vault-mcp-* and mcp-* target still works from this directory.
BROWSER_STACK_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../browser-stack)

# Apply pending Prisma migrations (also done automatically on server start).
migrate: env
	$(COMPOSE) run --rm happy-server pnpm exec prisma migrate deploy --schema=prisma/schema.prisma

# The vault (Vaultwarden + the filler, compose project happy-vault) and the browser stack
# (project happy-browser) together. Two projects, run in order: the browser's containers,
# env files and pod labels are keyed to its own project name, so it is not merged in with
# compose include:. Host processes (agents, vault-mcp, the bridge's stdio MCP,
# agentgateway) are not touched.
stack-up:
	$(MAKE) --no-print-directory vault-up
	$(MAKE) --no-print-directory browser-up

stack-down:
	$(MAKE) --no-print-directory browser-down
	$(MAKE) --no-print-directory vault-down

-include voice.mk
-include cli.mk
-include vault.mk
-include $(BROWSER_STACK_DIR)/browser.mk
-include $(BROWSER_STACK_DIR)/filler.mk
-include $(BROWSER_STACK_DIR)/register.mk
-include $(BROWSER_STACK_DIR)/gateway.mk
-include svc/svc.mk
