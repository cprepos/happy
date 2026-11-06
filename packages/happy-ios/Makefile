# happy-ios builds and tests on prep-pro, driven from Linux over ssh.
# See scripts/prep-pro/remote.sh for what each target does.
#   make ios-test-fast [CLEAN=1] [WORKERS=4] [DEVICE=0] [COMMIT=<rev>]
#   make ios-build-device [CONFIG=Preview|Debug] [PHONE_TS=<ts>] [CLEAN=1]
#   make ios-build-ipad-mac [CONFIG=Preview|Debug] [PHONE_TS=<ts>] [CLEAN=1]
#   make ios-fast-attach RUN=<ts>
#   make ios-fast-runs

SHELL := /bin/bash
REMOTE := scripts/prep-pro/remote.sh

export HOST COMMIT CONFIG PHONE_TS WORKERS CLEAN CACHE DEVICE RETRY KEEP_SIMS WAIT_FOREIGN WAIT_MAX

.PHONY: ios-test-fast ios-build-device ios-build-ipad-mac ios-fast-attach ios-fast-runs

ios-test-fast:
	$(REMOTE) test

ios-build-device:
	$(REMOTE) device

ios-build-ipad-mac:
	$(REMOTE) ipad-mac

ios-fast-attach:
	$(REMOTE) attach $(RUN)

ios-fast-runs:
	$(REMOTE) runs
