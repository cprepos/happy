# The browser node with Google Chrome (stable), built locally on top of the pinned upstream
# auto-browser node image. Opt-in: BROWSER_NODE_CHROME=1 in .env.browser (or on the make line)
# builds it with `make browser-node-chrome` and runs it for browser-node and every pod; unset,
# the stack runs the upstream image and its bundled Chrome for Testing as before.
#
# Google Chrome is Google's proprietary build, under the Google Chrome Terms of Service: it may
# be installed and run here, but an image containing it must not be published or redistributed.
# Build it locally; never push it to a registry.
#
# What changes from the upstream image, and nothing else:
#   - google-chrome-stable, one exact version, from Google's own .deb, checked against the
#     SHA256 below before it is installed. The hash was read from Google's apt index
#     (dl.google.com/linux/chrome/deb, dists/stable/main/binary-amd64/Packages), whose hash is in
#     InRelease, signed by Google's Linux packages key (primary EB4C 1BFD 4F04 2F6D DDCC EC91
#     7721 F63B D38B 4796). A new version means a new CHROME_VERSION and CHROME_SHA256 from the
#     same verified index.
#   - No update path: /etc/default/google-chrome tells the package's scripts never to add
#     Google's apt repo, its cron job is removed, and no repo is left in sources.list.d. The
#     container never updates Chrome; a rebuild with a new version does.
#   - The image's managed policy (auto-browser.json, from /etc/chromium/policies/managed) is
#     copied to Chrome's path, /etc/opt/chrome/policies/managed. kiosk/policy.json is mounted
#     there at run time, as it is at the Chromium and Chrome for Testing paths.
#   - BROWSER_EXECUTABLE_PATH names Chrome's binary; kiosk/happy-kiosk.mjs launches it through
#     Playwright's executablePath. The Chromium Playwright downloaded stays in /ms-playwright,
#     unused by the node.
#
# No USER here, as upstream: compose and the launcher run the container as BROWSER_NODE_UID
# (1994), with no capabilities, no-new-privileges, a read-only root and the same seccomp profile.
# Chrome's setuid chrome-sandbox cannot work under no-new-privileges; Chrome uses its user
# namespace sandbox instead, as Chromium does here (BROWSER_SANDBOX=auto checks it).
ARG BASE_IMAGE=ghcr.io/lvcidpsyche/auto-browser-browser-node:1.14.0@sha256:d5c1672e5816edd5beb38085016d4431adf0c4d39a6b41338c6fc60acb63ead1
FROM ${BASE_IMAGE}

ARG CHROME_VERSION=157.0.8103.50-1
ARG CHROME_SHA256=92148bd14dc05823a64061c2fafcf20d4d82b3fc56f5831206f16d2ac9ee3f79

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root
RUN set -eux; \
    printf 'repo_add_once="false"\nrepo_reenable_on_distupgrade="false"\n' >/etc/default/google-chrome; \
    deb="/tmp/google-chrome-stable_${CHROME_VERSION}_amd64.deb"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$deb" \
      "https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_${CHROME_VERSION}_amd64.deb"; \
    echo "${CHROME_SHA256}  $deb" | sha256sum -c -; \
    apt-get update; \
    apt-get install -y --no-install-recommends "$deb"; \
    rm -f "$deb" /etc/cron.daily/google-chrome; \
    rm -f /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/google-chrome.sources \
      /etc/apt/trusted.gpg.d/google-chrome.gpg /usr/share/keyrings/google-chrome.gpg; \
    ! grep -rqs 'dl.google.com' /etc/apt/sources.list /etc/apt/sources.list.d/; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    mkdir -p /etc/opt/chrome/policies/managed; \
    cp /etc/chromium/policies/managed/auto-browser.json /etc/opt/chrome/policies/managed/auto-browser.json; \
    v="$(/opt/google/chrome/chrome --version 2>/dev/null)"; test "${v%% }" = "Google Chrome ${CHROME_VERSION%-*}"

ENV BROWSER_EXECUTABLE_PATH=/opt/google/chrome/chrome
LABEL org.opencontainers.image.title="happy-browser-node-chrome" \
      org.opencontainers.image.description="auto-browser node 1.14.0 with Google Chrome stable; local build, not for redistribution" \
      happy-browser.chrome-version="${CHROME_VERSION}"
