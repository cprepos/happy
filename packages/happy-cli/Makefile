# Targets for happy-cli test pipelines.

.PHONY: restart-integration

# Real-process restart-agent integration test (scratch daemon, real agents,
# real self-hosted server). Knobs: RUNS, FLAVORS, SCENARIOS (see
# src/session/restart.integration.test.ts).
RUNS ?= 3
FLAVORS ?= opencode-tui,opencode-acp,claude,codex
SCENARIOS ?= 1,2,3,4,5,6

restart-integration:
	HAPPY_RESTART_IT_RUNS=$(RUNS) HAPPY_RESTART_IT_FLAVORS=$(FLAVORS) HAPPY_RESTART_IT_SCENARIOS=$(SCENARIOS) \
		pnpm exec vitest run --project integration-restart
