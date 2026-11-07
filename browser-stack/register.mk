# Register the live browser bridge (and the vault MCP server, when present) with Codex, Gemini,
# Antigravity, Claude and Happy Agent here, and with the harnesses on prep-air and prep-pro
# (their files edited over ssh, run on prep-ml). prep-ml's own opencode config is never touched.
# Originals go to <repo>/trash/<ts>_mcp-configs/, a Mac's to its own ~/happy-trash/<ts>_mcp-configs/.
#   DRY=1             say what would change
#   NO_REMOTE=1       leave the Macs alone
#   MAC_TRANSPORT=gateway|ssh   how Mac entries reach prep-ml (ssh is the rollback)
#   MAC_ONLY='prep-air:claude prep-pro'   only these Macs (and harnesses)
# See scripts/mcp-register.py. Included from browser-stack/Makefile and selfhost/Makefile.
REGISTER_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/scripts
MCP_REGISTER = python3 $(REGISTER_DIR)/mcp-register.py $(if $(DRY),--dry-run) $(if $(NO_REMOTE),--no-remote) $(if $(MAC_TRANSPORT),--mac-transport $(MAC_TRANSPORT)) $(if $(MAC_ONLY),--only '$(MAC_ONLY)')

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
