# Self-hosted Happy: server + Postgres via Docker Compose.
# Run from this directory: `make up`, `make status`, `make logs`.

SHELL := /bin/bash
COMPOSE := docker compose --project-directory $(CURDIR) -f $(CURDIR)/docker-compose.yml --env-file $(CURDIR)/.env
# The same, with the "rs" profile on: the Rust server (happy-server-rs) is addressable.
COMPOSE_RS := $(COMPOSE) --profile rs

.PHONY: help env build up down status logs migrate webapp-dir stack-up stack-down server-ts server-rs server-rs-build

help:
	@echo "Targets: env build up down status logs migrate"
	@echo "Server:  server-ts server-rs server-rs-build (switch between the TypeScript and the Rust server)"
	@echo "Stack:   stack-up stack-down (Vaultwarden, then the browser stack; the filler is its own systemd unit)"

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
	$(COMPOSE_RS) stop happy-server-rs
	$(COMPOSE) up -d --build postgres happy-server

down:
	$(COMPOSE_RS) down

status:
	$(COMPOSE_RS) ps
	@echo
	@printf "local  /      : HTTP "; curl -sS -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:3005/ || echo "unreachable"; echo
	@printf "local  /health: "; curl -fsS --max-time 5 http://127.0.0.1:3005/health || echo "unreachable"; echo
	@echo
	@$(MAKE) --no-print-directory vault-status || echo "vault-status: FAILED"

logs:
	$(COMPOSE_RS) logs -f --tail=200

# Switching servers. happy-server (TypeScript) and happy-server-rs (Rust) share the database,
# the port, the data volume and the web app, and must never run at the same time: each target
# stops the other server first, then starts its own and waits until it is healthy. Neither
# rebuilds an image that exists (`make build` / `make server-rs-build` do), so switching back
# is quick and uses what ran before.
server-ts: env webapp-dir
	$(COMPOSE_RS) stop happy-server-rs
	$(COMPOSE) up -d --wait --wait-timeout 180 postgres happy-server
	@printf "server-ts: GET / -> "; curl -fsS --max-time 5 http://127.0.0.1:3005/ -H 'Accept: text/plain' | head -c 200; echo

server-rs: env webapp-dir
	$(COMPOSE) stop happy-server
	$(COMPOSE_RS) up -d --wait --wait-timeout 180 postgres happy-server-rs
	@printf "server-rs: GET / -> "; curl -fsS --max-time 5 http://127.0.0.1:3005/ -H 'Accept: text/plain' | head -c 200; echo

# Rebuilds the Rust server image from HAPPY_SERVER_RS_CONTEXT (see docker-compose.yml) without
# touching the running server; `make server-rs` then starts it.
server-rs-build: env
	$(COMPOSE_RS) build happy-server-rs

# The browser stack (live browser, bridge, filler, vault MCP server, MCP registration) lives in
# ../browser-stack; its make fragments are included here so every browser-*, filler-*,
# vault-mcp-* and mcp-* target still works from this directory.
BROWSER_STACK_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../browser-stack)

# Apply pending Prisma migrations (also done automatically on server start).
migrate: env
	$(COMPOSE) run --rm happy-server pnpm exec prisma migrate deploy --schema=prisma/schema.prisma

# Vaultwarden (the standalone container vaultwarden, vault.mk) and the browser stack (compose
# project happy-browser, browser.mk) together, in order. The secret filler is not touched: it
# is a systemd user unit of the happy-filler account (browser-stack/filler.mk), and keeps
# running; make filler-status shows it. Host processes (agents, vault-mcp, the bridge's stdio
# MCP, agentgateway) are not touched either.
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
