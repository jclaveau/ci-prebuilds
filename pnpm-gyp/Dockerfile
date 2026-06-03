# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood-node:latest
FROM ${BASE_IMAGE}

# Renovate will update this (keep in sync with pnpm/Dockerfile)
ARG PNPM_VERSION=9.15.3

# The node-gyp variant: pnpm + the C/C++ toolchain that the base gha-tools deliberately drops. Built as a
# SIBLING of the slim `pnpm` layer (both FROM node) so the two chains build in parallel. The pnpm install
# mirrors pnpm/Dockerfile — the repo re-installs per chain on purpose (symmetric graph over dedup). Use
# this (over slim {os}-{mode}-pnpm) when `pnpm install` compiles native addons; python3 comes from gha-tools.
LABEL org.opencontainers.image.description="pnpm + node-gyp build toolchain (build-essential) for native addons, Ubuntu based"

ENV PNPM_HOME="/home/runner/.local/share/pnpm"
ENV PATH="${PATH}:${PNPM_HOME}"

RUN echo "Install PNPM via the npm registry (SHA512-checked tarballs)" \
    && sudo npm install -g pnpm@${PNPM_VERSION}

RUN echo "Install the node-gyp toolchain (build-essential) for native addon compilation" \
    && sudo apt-get update \
    && sudo apt-get install -y --no-install-recommends build-essential \
    && sudo rm -rf /var/lib/apt/lists/*

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
