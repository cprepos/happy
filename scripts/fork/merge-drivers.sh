#!/usr/bin/env bash
# Sets up this clone's merge drivers named in .gitattributes. Git keeps
# drivers in .git/config, which is not committed, so each clone runs this
# once (make -C packages/happy-i18n merge-drivers).
#
# regenerated: files generated from packages/happy-i18n/translations. A
# merge keeps our side as it is (`true` leaves %A alone and reports no
# conflict); `make -C packages/happy-i18n translations` then generates
# them again from the merged catalogs.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config merge.regenerated.name "keep ours; generate again from the catalogs after the merge"
git config merge.regenerated.driver true
echo "merge driver 'regenerated' set; after a merge run: make -C packages/happy-i18n translations"
