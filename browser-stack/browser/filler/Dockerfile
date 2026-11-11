# The secret filler's image: the app on node 22, run as uid
# 1990 (the owner of /srv/happy-filler) with the same
# --disallow-code-generation-from-strings flag the systemd unit used. Built and
# run by selfhost/vault/compose.vault.yml (service filler; filler-admin for the
# setup commands in scripts/admin.mjs). The app files are root-owned and
# read-only to the process; its data is the bind-mounted /filler.
#
# node:22-alpine, pinned by its index digest (the same one the browser bridge
# runs, browser-stack/browser/compose.browser.yml).
#
# Dependencies, if any, come only from package-lock.json (npm ci: exact
# versions, integrity-checked, no install scripts, no dev dependencies), in a
# separate stage so npm's cache stays out of the image. Dependencies without a
# lockfile fail the build.
FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914 AS deps
WORKDIR /app
COPY package*.json ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev --ignore-scripts --no-audit --no-fund; \
    elif grep -q '"dependencies"' package.json; then echo "package.json has dependencies but no package-lock.json" >&2; exit 1; \
    else mkdir node_modules; fi

FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json server.mjs ./
COPY lib ./lib
COPY scripts ./scripts
RUN chmod -R a-w /app

ENV FILLER_HOME=/filler \
    HOME=/tmp \
    NODE_OPTIONS=

USER 1990:1990
CMD ["node", "--disallow-code-generation-from-strings", "server.mjs"]
