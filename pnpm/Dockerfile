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
