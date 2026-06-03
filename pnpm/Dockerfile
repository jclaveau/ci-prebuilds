# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood-node:latest
FROM ${BASE_IMAGE}

# Renovate will update this
ARG PNPM_VERSION=9.15.3


# LABEL maintainer="your-email@example.com"
# LABEL org.opencontainers.image.source="https://github.com/jclaveau/docker-images"
LABEL org.opencontainers.image.description="pnpm on top of Node in Ubuntu based DinD as Github Actions Container"


# https://github.com/pnpm/pnpm/issues/4495#issuecomment-1317831712
ENV PNPM_HOME="/home/runner/.local/share/pnpm"
ENV PATH="${PATH}:${PNPM_HOME}"


RUN echo "Install PNPM via the npm registry (SHA512-checked tarballs)" \
    && sudo npm install -g pnpm@${PNPM_VERSION}

RUN echo "Normalize PNPM-state dirs to 2775 runner:runner so non-1001 callers in --group-add 1001 can write at runtime (mirrors the /opt/hostedtoolcache treatment in the gha-tools base). Recursive because a prior RUN's pnpm install may have populated subtrees at mode 0755." \
    && sudo mkdir -p \
         /home/runner/.local/share/pnpm \
         /home/runner/.cache/pnpm \
         /home/runner/.config/pnpm \
    && sudo chown -R runner:runner /home/runner/.local /home/runner/.cache /home/runner/.config \
    && sudo find /home/runner/.local /home/runner/.cache /home/runner/.config \
         -type d -exec chmod 2775 {} + \
    && sudo find /home/runner/.local /home/runner/.cache /home/runner/.config \
         -type f -exec chmod g+w {} +
