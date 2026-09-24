# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood-pnpm:latest
FROM ${BASE_IMAGE}

# Renovate will update this
ARG PLAYWRIGHT_VERSION=1.62.1


# LABEL maintainer="your-email@example.com"
# LABEL org.opencontainers.image.source="https://github.com/jclaveau/docker-images"
LABEL org.opencontainers.image.description="Playwright in Ubuntu based DinD as Github Actions Container"


# https://playwright.dev/docs/browsers
ENV PLAYWRIGHT_BROWSERS_PATH='/home/runner/playwright-browsers'


# The `.links` entry is the one baked FILE a consumer has to write: re-running
# `playwright install` from the baked playwright-core hashes to the same entry
# and opens it for writing, so the group write the dirs got is not enough. 133
# bytes, written in this same RUN, so unlike the browser payload it costs no
# overlay copy-up.
RUN echo "Install Playwright globally https://playwright.dev/docs/docker#build-your-own-image" \
    && pnpm install -g playwright@${PLAYWRIGHT_VERSION} \
    && playwright install --with-deps --only-shell \
    && sudo share-dir-with-runner-group "${PNPM_HOME}" "${PLAYWRIGHT_BROWSERS_PATH}" \
    && sudo find "${PLAYWRIGHT_BROWSERS_PATH}/.links" -type f -exec chmod g+w {} +

# TODO
# - RUN pnpm env --global 22 https://pnpm.io/cli/env available with v10?
# - use asdf with ni ?
