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
