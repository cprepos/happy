# Register the live browser bridge (and the vault MCP server, when present) with Codex, Gemini,
# Antigravity, Claude and Happy Agent, and over ssh with the harnesses on prep-air and prep-pro,
# opencode included (run on prep-ml, keyed by the chat's session id). prep-ml's own opencode
# config is never touched. Originals go to <repo>/trash/<ts>_mcp-configs/, a Mac's to its own
# ~/happy-trash/<ts>_mcp-configs/. DRY=1 says what would change; NO_REMOTE=1 leaves the Macs
# alone. See scripts/mcp-register.py. Included from browser-stack/Makefile and selfhost/Makefile.
REGISTER_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/scripts
MCP_REGISTER = python3 $(REGISTER_DIR)/mcp-register.py $(if $(DRY),--dry-run) $(if $(NO_REMOTE),--no-remote)

.PHONY: mcp-register mcp-unregister mcp-check mcp-register-test
# Its tests run it against a scratch home folder, never the real one.
mcp-register-test:
	cd $(REGISTER_DIR) && python3 -m unittest -v test_mcp_register

mcp-register:
	$(MCP_REGISTER) register

mcp-unregister:
	$(MCP_REGISTER) unregister

mcp-check:
	$(MCP_REGISTER) check
