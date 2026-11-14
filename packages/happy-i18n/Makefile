# The native catalogs generated from translations/*.json.
#   make -C packages/happy-i18n translations    generate iOS and Android again
#   make -C packages/happy-i18n merge-drivers   set up this clone's merge
#                                               driver for those files
#                                               (.gitattributes)

SHELL := /bin/bash
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

.PHONY: translations merge-drivers

translations:
	node $(ROOT)/packages/happy-ios/scripts/generate-translations.mjs
	node $(ROOT)/packages/happy-ios/scripts/translation-counts.mjs
	node $(ROOT)/packages/happy-android/tools/translations/generate.mjs

merge-drivers:
	$(ROOT)/scripts/plugins/merge-drivers.sh
