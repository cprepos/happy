# Web app build targets. Included from selfhost/Makefile via `-include webapp.mk`.
WEBAPP_MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

# build-webapp.sh swaps selfhost/webapp for a new directory and moves the old
# one to trash. A running happy-server keeps its bind mount on the old
# directory, so after a successful build the container is recreated to mount
# the new one. Skipped when the stack is not running.
.PHONY: webapp
webapp: ## Build the web app into selfhost/webapp (HAPPY_PUBLIC_URL overrides the server URL)
	bash $(WEBAPP_MK_DIR)scripts/build-webapp.sh
	@if [ -f $(CURDIR)/.env ] && [ -n "$$($(COMPOSE) -p happy-selfhost ps --status running -q happy-server 2>/dev/null)" ]; then \
		echo "Recreating happy-server so it serves the new webapp directory"; \
		$(COMPOSE) -p happy-selfhost up -d --force-recreate --no-deps happy-server; \
	else \
		echo "happy-server is not running; the new webapp is served on next start"; \
	fi
