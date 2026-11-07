# The LAN gateway the Macs reach the stack through (gateway/gateway-config.py, client/).
# Included from browser-stack/Makefile and selfhost/Makefile.
#   make gateway-config [WRITE=1] [ROUTES=browser,vault]   the stack's blocks in the host
#        agentgateway config: a redacted diff and a validation; WRITE=1 backs it up and writes it
#   make gateway-keys    a 64-hex-digit key per Mac in ~/.config/browser-stack/gateway-keys (600)
#   make gateway-test    the gateway client's tests
#   make gateway-mac-install HOST=<mac>   the client and that Mac's key onto the Mac
GATEWAY_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
GATEWAY_CONFIG = python3 $(GATEWAY_DIR)/gateway/gateway-config.py

.PHONY: gateway-config gateway-keys gateway-test
gateway-config:
	$(GATEWAY_CONFIG) $(if $(WRITE),write,show) $(if $(ROUTES),--routes $(ROUTES))

gateway-keys:
	$(GATEWAY_CONFIG) keys

gateway-test:
	cd $(GATEWAY_DIR) && node --test client/test/

# make gateway-mac-install HOST=prep-air   the client and that Mac's key onto the Mac (setup, over ssh)
.PHONY: gateway-mac-install
gateway-mac-install:
	@test -n "$(HOST)" || { echo "HOST=prep-air or HOST=prep-pro"; exit 2; }
	$(GATEWAY_DIR)/gateway/mac-install.sh $(HOST)
