# CLI targets for the self-hosted setup. Included by selfhost/Makefile.
#
#   make cli-build     build packages/happy-cli
#   make cli-config    point the CLI at the self-hosted server (backs up settings first)
#   make cli-install   build and link the CLI as `happy` (npm link, or CLI_BIN_DIR if the npm prefix isn't writable)
#
# Variables:
#   HAPPY_PUBLIC_URL   public URL of the server + webapp
#   HAPPY_HOME_DIR     CLI home directory (same variable the CLI reads; default ~/.happy)

CLI_MK_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CLI_REPO_ROOT := $(abspath $(CLI_MK_DIR)/..)

HAPPY_PUBLIC_URL ?= https://happy.girthbass.duckdns.org
HAPPY_HOME_DIR ?= $(HOME)/.happy
CLI_SETTINGS_FILE := $(HAPPY_HOME_DIR)/settings.json

# Sets serverUrl/webappUrl in settings.json, keeping every other key; written atomically.
define CLI_CONFIG_JS
const fs = require("fs"), path = require("path");
const file = process.env.SETTINGS_FILE;
const url = process.env.PUBLIC_URL.replace(/\/+$$/, "");
if (!/^https?:\/\/[^/]+/.test(url)) { console.error("HAPPY_PUBLIC_URL must be an http(s) URL: " + url); process.exit(1); }
let s = { schemaVersion: 2, onboardingCompleted: false };
if (fs.existsSync(file)) s = JSON.parse(fs.readFileSync(file, "utf8"));
s.serverUrl = url;
s.webappUrl = url;
fs.mkdirSync(path.dirname(file), { recursive: true });
const tmp = file + ".tmp-" + process.pid;
fs.writeFileSync(tmp, JSON.stringify(s, null, 2) + "\n");
fs.renameSync(tmp, file);
console.log("Set serverUrl and webappUrl to " + url + " in " + file);
endef
export CLI_CONFIG_JS

.PHONY: cli-build cli-config cli-install

cli-build:
	cd "$(CLI_REPO_ROOT)" && pnpm install --frozen-lockfile && pnpm --filter happy build

cli-config:
	@set -e; \
	if [ -f "$(CLI_SETTINGS_FILE)" ]; then \
		backup_dir="$(CLI_REPO_ROOT)/trash/$$(date +%Y%m%d_%H%M%S)_happy_settings"; \
		mkdir -p "$$backup_dir"; \
		cp -p "$(CLI_SETTINGS_FILE)" "$$backup_dir/settings.json"; \
		printf 'Backup of %s taken by make cli-config before setting serverUrl/webappUrl to %s.\n' \
			"$(CLI_SETTINGS_FILE)" "$(HAPPY_PUBLIC_URL)" > "$$backup_dir/NOTE.txt"; \
		echo "Backed up $(CLI_SETTINGS_FILE) to $$backup_dir"; \
	fi
	@SETTINGS_FILE="$(CLI_SETTINGS_FILE)" PUBLIC_URL="$(HAPPY_PUBLIC_URL)" node -e "$$CLI_CONFIG_JS"

# npm link needs a writable global prefix. When it isn't (e.g. /usr), build and symlink
# `happy` / `happy-mcp` into CLI_BIN_DIR instead (must be on PATH).
CLI_BIN_DIR ?= $(HOME)/.local/bin

cli-install:
	@if [ -w "$$(npm config get prefix)/lib/node_modules" ]; then \
		cd "$(CLI_REPO_ROOT)" && pnpm --filter happy cli:install; \
	else \
		cd "$(CLI_REPO_ROOT)/packages/happy-cli" && pnpm run build && \
		mkdir -p "$(CLI_BIN_DIR)" && \
		ln -sfn "$(CLI_REPO_ROOT)/packages/happy-cli/bin/happy.mjs" "$(CLI_BIN_DIR)/happy" && \
		ln -sfn "$(CLI_REPO_ROOT)/packages/happy-cli/bin/happy-mcp.mjs" "$(CLI_BIN_DIR)/happy-mcp" && \
		echo "linked happy and happy-mcp into $(CLI_BIN_DIR)"; \
	fi
