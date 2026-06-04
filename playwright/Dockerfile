# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood-pnpm:latest
FROM ${BASE_IMAGE}

# Renovate will update this
ARG PLAYWRIGHT_VERSION=1.55.1


# LABEL maintainer="your-email@example.com"
# LABEL org.opencontainers.image.source="https://github.com/jclaveau/docker-images"
LABEL org.opencontainers.image.description="Playwright in Ubuntu based DinD as Github Actions Container"


# https://playwright.dev/docs/browsers
ENV PLAYWRIGHT_BROWSERS_PATH='/home/runner/playwright-browsers'


RUN echo "Install Playwright globally https://playwright.dev/docs/docker#build-your-own-image" \
    && pnpm install -g playwright@${PLAYWRIGHT_VERSION} \
    && playwright install --with-deps --only-shell

# TODO
# - RUN pnpm env --global 22 https://pnpm.io/cli/env available with v10?
# - use asdf with ni ?
