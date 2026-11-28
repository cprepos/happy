# ElevenLabs-compatible conversation server (packages/elevenlabs-server, compose.elevenlabs.yml).
# Included from selfhost/Makefile via `-include elevenlabs.mk`.
#   make elevenlabs-server        build if needed, start, wait until healthy
#   make elevenlabs-server-build  rebuild the image without touching the running container
#   make elevenlabs-server-down / -logs / -status
#   make elevenlabs-server-test   unit tests (packages/elevenlabs-server/tests)
#   make elevenlabs-server-e2e    the Swift SDK path end to end through Caddy (voice.mk's
#                                 voice-agent-e2e-el with VOICE_AGENT_E2E_EL_TOKEN_URL)

EL_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
EL_PKG := $(abspath $(EL_DIR)/../packages/elevenlabs-server)
EL_COMPOSE := docker compose -p elevenlabs-server -f $(EL_DIR)/compose.elevenlabs.yml --env-file $(EL_DIR)/.env
EL_PORT ?= 3015
EL_VENV ?= $(HOME)/.cache/elevenlabs-server-venv
ELEVENLABS_TOKEN_URL ?= https://happy.girthbass.duckdns.org/elevenlabs/v1/convai/conversation/token
ELEVENLABS_E2E_ARGS ?=

.PHONY: elevenlabs-server elevenlabs-server-build elevenlabs-server-venv elevenlabs-server-down elevenlabs-server-logs elevenlabs-server-status elevenlabs-server-test elevenlabs-server-e2e

elevenlabs-server:
	$(EL_COMPOSE) up -d --wait --wait-timeout 120 elevenlabs-server
	@printf "elevenlabs-server: GET /health -> "; curl -fsS --max-time 5 http://127.0.0.1:$(EL_PORT)/health || echo "unreachable"; echo

elevenlabs-server-build:
	$(EL_COMPOSE) build elevenlabs-server

elevenlabs-server-down:
	$(EL_COMPOSE) down

elevenlabs-server-logs:
	$(EL_COMPOSE) logs -f --tail=200 elevenlabs-server

elevenlabs-server-status:
	$(EL_COMPOSE) ps
	@printf "local  /health: "; curl -fsS --max-time 5 http://127.0.0.1:$(EL_PORT)/health || echo "unreachable"; echo
	@printf "caddy  /health: "; curl -fsS --max-time 5 $(patsubst %/v1/convai/conversation/token,%/health,$(ELEVENLABS_TOKEN_URL)) || echo "unreachable"; echo

elevenlabs-server-venv:
	@if [ ! -x "$(EL_VENV)/bin/python" ]; then \
		echo "== creating $(EL_VENV)"; \
		UV=$$(command -v uv || echo $(HOME)/.local/bin/uv); \
		if [ -x "$$UV" ]; then "$$UV" venv -q -p 3.12 "$(EL_VENV)" && "$$UV" pip install -q -p "$(EL_VENV)/bin/python" -r $(EL_PKG)/requirements.txt pytest==8.3.5; \
		else python3 -m venv "$(EL_VENV)" && "$(EL_VENV)/bin/pip" install -q -r $(EL_PKG)/requirements.txt pytest==8.3.5; fi; \
	fi

elevenlabs-server-test: elevenlabs-server-venv
	cd $(EL_PKG) && "$(EL_VENV)/bin/python" -I -m pytest -q -p no:cacheprovider tests

# The SDK path end to end, through Caddy: token from the server, LiveKit through its /rtc proxy.
elevenlabs-server-e2e:
	$(MAKE) --no-print-directory -f $(EL_DIR)/voice.mk voice-agent-e2e-el VOICE_AGENT_E2E_EL_TOKEN_URL=$(ELEVENLABS_TOKEN_URL) VOICE_AGENT_E2E_EL_ARGS="$(ELEVENLABS_E2E_ARGS)"
