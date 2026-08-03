# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood:latest
FROM ${BASE_IMAGE}

# Renovate will update this
ARG NODE_VERSION=22.23.2


LABEL org.opencontainers.image.description="Node + npm (slim, no compiler) in Ubuntu based DinD as Github Actions Container"


# Node + npm only — no node-gyp toolchain here (the base gha-tools no longer ships a compiler). Native
# addon builds use the `-gyp` variant ({os}-{mode}-pnpm-gyp), which adds build-essential. See README.
RUN echo "Install Node.js (NodeSource)" \
    && sudo curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION%%.*}.x | sudo bash - \
    && sudo apt-get install -y nodejs \
    && sudo rm -rf /var/lib/apt/lists/*
