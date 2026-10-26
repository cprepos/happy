# Web app build targets. Included from selfhost/Makefile via `-include webapp.mk`.
WEBAPP_MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

.PHONY: webapp
webapp: ## Build the web app into selfhost/webapp (HAPPY_PUBLIC_URL overrides the server URL)
	bash $(WEBAPP_MK_DIR)scripts/build-webapp.sh
