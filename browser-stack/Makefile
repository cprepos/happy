# Browser stack: the live browser bridge, the vault MCP server, the filler, and
# the LAN gateway the Macs reach them through. Run from anywhere:
#   make -C browser-stack <target>

SHELL := /bin/bash
HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: help gateway-config gateway-keys gateway-test

help:
	@echo "Targets: gateway-config [WRITE=1] [ROUTES=browser,vault] gateway-keys gateway-test"

# The browser stack's marked blocks in the host agentgateway config (LAN gateway,
# per-Mac keys, /browser and /vault routes). Shows the diff with keys redacted and
# validates it; WRITE=1 backs the config up to ../happy-trash and writes it.
GATEWAY_CONFIG = python3 $(HERE)/gateway/gateway-config.py
gateway-config:
	$(GATEWAY_CONFIG) $(if $(WRITE),write,show) $(if $(ROUTES),--routes $(ROUTES))

# A 64-hex-digit key per Mac in ~/.config/browser-stack/gateway-keys (mode 600).
# Never overwrites one; never prints one.
gateway-keys:
	$(GATEWAY_CONFIG) keys

# The gateway client's tests (a scratch agentgateway on loopback when one is installed).
gateway-test:
	cd $(HERE) && node --test client/test/
