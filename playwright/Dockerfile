# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood-pnpm:latest
FROM ${BASE_IMAGE}

# Renovate will update this
ARG PLAYWRIGHT_VERSION=1.50.1


# LABEL maintainer="your-email@example.com"
# LABEL org.opencontainers.image.source="https://github.com/jclaveau/docker-images"
LABEL org.opencontainers.image.description="Playwright in Ubuntu based DinD as Github Actions Container"


# https://playwright.dev/docs/browsers
ENV PLAYWRIGHT_BROWSERS_PATH='/home/runner/playwright-browsers'


RUN echo "Install Playwright globally https://playwright.dev/docs/docker#build-your-own-image" \
    && pnpm install -g playwright@${PLAYWRIGHT_VERSION} \
    && playwright install --with-deps --only-shell

RUN echo "Normalize PNPM-state dirs to 2775 runner:runner so non-1001 callers in --group-add 1001 can write at runtime (mirrors the /opt/hostedtoolcache treatment in the gha-tools base). Recursive because the prior pnpm install -g playwright populates ~/.local/share/pnpm/global/<v>/node_modules/… at mode 0755 — the deep subtree the consumer would write into for a sibling `pnpm install -g`." \
    && sudo mkdir -p \
         /home/runner/.local/share/pnpm \
         /home/runner/.cache/pnpm \
         /home/runner/.config/pnpm \
    && sudo chown -R runner:runner /home/runner/.local /home/runner/.cache /home/runner/.config \
    && sudo find /home/runner/.local /home/runner/.cache /home/runner/.config \
         -type d -exec chmod 2775 {} + \
    && sudo find /home/runner/.local /home/runner/.cache /home/runner/.config \
         -type f -exec chmod g+w {} +

# TODO
# - RUN pnpm env --global 22 https://pnpm.io/cli/env available with v10?
# - use asdf with ni ?
