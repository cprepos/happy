# Browser stack: the live browser (auto-browser, per-chat pods, the live bridge), the secret
# filler, the vault MCP server, MCP registration, and the LAN gateway the Macs use.
# Run here or with `make -C browser-stack <target>`; selfhost/Makefile includes the same
# fragments, so `make -C selfhost <target>` works too. See README.md.

SHELL := /bin/bash

.PHONY: help test
help:
	@echo "browser-*: browser-up browser-down browser-status browser-logs browser-verify browser-bridge-test ... (browser.mk)"
	@echo "filler-*:  as prep: filler-status filler-audit filler-test filler-token-take vault-mcp-test; as happy-filler: filler-install COMMIT=<sha> filler-restart ... (filler.mk)"
	@echo "mcp-*:     mcp-register mcp-check mcp-unregister mcp-register-test (register.mk)"
	@echo "gateway-*: gateway-config [WRITE=1] gateway-keys gateway-test (gateway.mk)"
	@echo "test:      every unit suite here (bridge, launcher, identity, filler, vault MCP, client, mcp-register)"

include browser.mk
include filler.mk
include register.mk
include gateway.mk

test: browser-bridge-test filler-test vault-mcp-test gateway-test mcp-register-test
