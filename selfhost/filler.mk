# The secret filler (selfhost/browser/filler): types vault secrets into the
# agent's browser by name, so the agent never sees a value. Included from
# selfhost/Makefile via `-include filler.mk`. See selfhost/browser/filler/README.md.

FILLER_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/browser/filler

.PHONY: filler-test

filler-test:
	cd $(FILLER_DIR) && node --test test/*.test.mjs
