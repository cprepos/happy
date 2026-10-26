# Self-hosted Happy: server + Postgres via Docker Compose.
# Run from this directory: `make up`, `make status`, `make logs`.

SHELL := /bin/bash
COMPOSE := docker compose --project-directory $(CURDIR) -f $(CURDIR)/docker-compose.yml --env-file $(CURDIR)/.env

.PHONY: help env build up down status logs migrate

help:
	@echo "Targets: env build up down status logs migrate"

# Create .env with random secrets if it does not exist yet (never overwrites).
env:
	@if [ -f .env ]; then echo ".env already exists, leaving it untouched"; else \
		cp .env.example .env && \
		sed -i "s/^HANDY_MASTER_SECRET=.*/HANDY_MASTER_SECRET=$$(openssl rand -hex 32)/" .env && \
		sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$$(openssl rand -hex 24)/" .env && \
		chmod 600 .env && echo "Wrote .env"; fi

webapp:
	@mkdir -p webapp

build: env
	$(COMPOSE) build happy-server

up: env webapp
	$(COMPOSE) up -d --build postgres happy-server

down:
	$(COMPOSE) down

status:
	$(COMPOSE) ps
	@echo
	@printf "local  /      : HTTP "; curl -sS -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:3005/ || echo "unreachable"; echo
	@printf "local  /health: "; curl -fsS --max-time 5 http://127.0.0.1:3005/health || echo "unreachable"; echo

logs:
	$(COMPOSE) logs -f --tail=200

# Apply pending Prisma migrations (also done automatically on server start).
migrate: env
	$(COMPOSE) run --rm happy-server pnpm exec prisma migrate deploy --schema=prisma/schema.prisma

-include voice.mk
-include cli.mk
-include webapp.mk
