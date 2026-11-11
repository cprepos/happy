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
#   - Two Debian font packages the upstream image lacks, so pages in Chinese, Japanese and Korean
#     and emoji render as glyphs rather than empty boxes: fonts-noto-cjk (Noto Sans/Serif CJK)
#     and fonts-noto-color-emoji. Pinned as Chrome is: one exact .deb each, from
#     snapshot.debian.org at the date the base image's Debian sources name (FONTS_SNAPSHOT), each
#     checked against the SHA256 below before dpkg installs it. The hashes were read from that
#     snapshot's trixie Packages index, whose hash is in InRelease, signed by the Debian archive
#     key (debian-archive-keyring, as apt checks it). Neither package has dependencies, so no
#     apt index is fetched for them. A new font version means a new FONTS_SNAPSHOT and the
#     versions and hashes from that snapshot's verified index.
#
# The image tag (browser.mk) is the Chrome version and IMAGE_REVISION: <chrome>-<revision>, the
# revision raised for any change here that keeps the same Chrome.
#
# No USER here, as upstream: compose and the launcher run the container as BROWSER_NODE_UID
# (1994), with no capabilities, no-new-privileges, a read-only root and the same seccomp profile.
# Chrome's setuid chrome-sandbox cannot work under no-new-privileges; Chrome uses its user
# namespace sandbox instead, as Chromium does here (BROWSER_SANDBOX=auto checks it).
ARG BASE_IMAGE=ghcr.io/lvcidpsyche/auto-browser-browser-node:1.14.0@sha256:d5c1672e5816edd5beb38085016d4431adf0c4d39a6b41338c6fc60acb63ead1
FROM ${BASE_IMAGE}

ARG CHROME_VERSION=157.0.8103.50-1
ARG CHROME_SHA256=92148bd14dc05823a64061c2fafcf20d4d82b3fc56f5831206f16d2ac9ee3f79
ARG IMAGE_REVISION=2
ARG FONTS_SNAPSHOT=20261027T000000Z
ARG NOTO_CJK_VERSION=20240730+repack1-1
ARG NOTO_CJK_SHA256=f5dc28a754e17327d99f0a612134d92c8dd6187314ae967cb77f25df60860139
ARG NOTO_EMOJI_VERSION=2.051-0+deb13u1
ARG NOTO_EMOJI_SHA256=03141cd51c0e9ff8ad858fcf2d8234f8a00ae4d7a0872df43a71519359c54e8c

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

RUN set -eux; \
    pool="https://snapshot.debian.org/archive/debian/${FONTS_SNAPSHOT}/pool/main/f"; \
    cjk="/tmp/fonts-noto-cjk_${NOTO_CJK_VERSION}_all.deb"; \
    emoji="/tmp/fonts-noto-color-emoji_${NOTO_EMOJI_VERSION}_all.deb"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$cjk" "${pool}/fonts-noto-cjk/fonts-noto-cjk_${NOTO_CJK_VERSION//+/%2B}_all.deb"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$emoji" "${pool}/fonts-noto-color-emoji/fonts-noto-color-emoji_${NOTO_EMOJI_VERSION//+/%2B}_all.deb"; \
    printf '%s  %s\n' "${NOTO_CJK_SHA256}" "$cjk" "${NOTO_EMOJI_SHA256}" "$emoji" | sha256sum -c -; \
    dpkg -i "$cjk" "$emoji"; \
    rm -f "$cjk" "$emoji"; \
    test "$(dpkg-query -W -f '${Version}' fonts-noto-cjk)" = "1:${NOTO_CJK_VERSION}"; \
    test "$(dpkg-query -W -f '${Version}' fonts-noto-color-emoji)" = "${NOTO_EMOJI_VERSION}"; \
    fc-cache -s; \
    fc-list :lang=zh-cn family | grep 'Noto Sans CJK SC' >/dev/null; \
    fc-list :lang=ja family | grep 'Noto Sans CJK JP' >/dev/null; \
    fc-list :lang=ko family | grep 'Noto Sans CJK KR' >/dev/null; \
    fc-list : family | grep 'Noto Color Emoji' >/dev/null

ENV BROWSER_EXECUTABLE_PATH=/opt/google/chrome/chrome
LABEL org.opencontainers.image.title="happy-browser-node-chrome" \
      org.opencontainers.image.description="auto-browser node 1.14.0 with Google Chrome stable and Noto CJK and emoji fonts; local build, not for redistribution" \
      happy-browser.chrome-version="${CHROME_VERSION}" \
      happy-browser.image-revision="${IMAGE_REVISION}" \
      happy-browser.fonts="fonts-noto-cjk ${NOTO_CJK_VERSION}, fonts-noto-color-emoji ${NOTO_EMOJI_VERSION} (snapshot ${FONTS_SNAPSHOT})"
