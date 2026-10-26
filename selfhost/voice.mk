# Self-hosted voice stack targets. Included from selfhost/Makefile via `-include voice.mk`,
# but also usable directly: `make -f voice.mk voice-status`.
#
#   make voice-keys    generate .env.voice (LiveKit key pair) from .env.voice.example if missing
#   make voice-build   build the local STT image
#   make voice-up      start livekit, stt, tts, llm (detached)
#   make voice-down    stop and remove the voice containers (volumes and model cache kept)
#   make voice-status  container state + per-service health + GPU memory
#   make voice-logs    follow logs (SVC=llm to pick one service)
#   make voice-smoke   end-to-end smoke test of every service (see scripts/voice-smoke.sh)
#   make voice-try     browser test page (TTS, STT, full turn) on http://127.0.0.1:8899 (loopback only)

VOICE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
VOICE_ENV := $(VOICE_DIR)/.env.voice
VOICE_COMPOSE := docker compose -p happy-voice -f $(VOICE_DIR)/compose.voice.yml --env-file $(VOICE_ENV)
SVC ?=

.PHONY: voice-keys voice-build voice-up voice-down voice-status voice-logs voice-smoke voice-try

VOICE_TRY_VENV ?= $(HOME)/.cache/happy-voice-try-venv
VOICE_TRY_PORT ?= 8899

voice-keys:
	@if [ -f "$(VOICE_ENV)" ]; then \
		echo ".env.voice already exists, leaving it alone"; \
	else \
		key="API$$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 12)"; \
		secret="$$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 48)"; \
		sed -e "s|^LIVEKIT_API_KEY=.*|LIVEKIT_API_KEY=$$key|" \
		    -e "s|^LIVEKIT_API_SECRET=.*|LIVEKIT_API_SECRET=$$secret|" \
		    "$(VOICE_DIR)/.env.voice.example" > "$(VOICE_ENV)"; \
		chmod 600 "$(VOICE_ENV)"; \
		echo "wrote $(VOICE_ENV)"; \
	fi

$(VOICE_ENV):
	@$(MAKE) --no-print-directory -f $(VOICE_DIR)/voice.mk voice-keys

voice-build: $(VOICE_ENV)
	$(VOICE_COMPOSE) build stt

voice-up: $(VOICE_ENV)
	$(VOICE_COMPOSE) up -d --build $(SVC)
	@echo "LLM can take several minutes to load; watch with: make voice-status"

voice-down: $(VOICE_ENV)
	$(VOICE_COMPOSE) down

voice-status: $(VOICE_ENV)
	@$(VOICE_COMPOSE) ps
	@set -a; . "$(VOICE_ENV)"; set +a; \
	check() { printf '%-8s %-32s ' "$$1" "$$2"; out=$$(curl -fsS -m 3 "$$2" 2>/dev/null) && echo "OK $$(echo "$$out" | head -c 120)" || echo "DOWN"; }; \
	check livekit http://127.0.0.1:7880/; \
	check stt  http://127.0.0.1:$${STT_PORT:-8090}/health; \
	check tts  http://127.0.0.1:$${TTS_PORT:-8880}/health; \
	check llm  http://127.0.0.1:$${LLM_PORT:-8000}/v1/models
	@nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader

voice-logs: $(VOICE_ENV)
	$(VOICE_COMPOSE) logs -f --tail=200 $(SVC)

voice-smoke: $(VOICE_ENV)
	@bash $(VOICE_DIR)/scripts/voice-smoke.sh

# Static page + same-origin proxy to the services; binds 127.0.0.1 only.
# From another machine: ssh -L $(VOICE_TRY_PORT):127.0.0.1:$(VOICE_TRY_PORT) <user>@<host>, then http://localhost:$(VOICE_TRY_PORT)
voice-try: $(VOICE_ENV)
	@if [ ! -x "$(VOICE_TRY_VENV)/bin/python" ]; then \
		echo "== creating $(VOICE_TRY_VENV)"; \
		if command -v uv >/dev/null 2>&1; then uv venv -q -p 3.12 "$(VOICE_TRY_VENV)" && uv pip install -q -p "$(VOICE_TRY_VENV)/bin/python" -r $(VOICE_DIR)/voice-test/requirements.txt; \
		else python3 -m venv "$(VOICE_TRY_VENV)" && "$(VOICE_TRY_VENV)/bin/pip" install -q -r $(VOICE_DIR)/voice-test/requirements.txt; fi; \
	fi
	@set -a; . "$(VOICE_ENV)"; set +a; VOICE_TRY_PORT=$(VOICE_TRY_PORT) exec "$(VOICE_TRY_VENV)/bin/python" -I $(VOICE_DIR)/voice-test/server.py
