# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood:latest
FROM ${BASE_IMAGE}

# Renovate will update this
ARG NODE_VERSION=24.22.0


LABEL org.opencontainers.image.description="Node + npm (slim, no compiler) in Ubuntu based DinD as Github Actions Container"


# Node + npm only — no node-gyp toolchain here (the base gha-tools no longer ships a compiler). Native
# addon builds use the `-gyp` variant ({os}-{mode}-pnpm-gyp), which adds build-essential. See README.
RUN echo "Install Node.js (NodeSource)" \
    && sudo curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION%%.*}.x | sudo bash - \
    && sudo apt-get install -y nodejs \
    && sudo rm -rf /var/lib/apt/lists/*

# A node in /usr/bin is invisible to `actions/setup-node`, which would download another one over it
# (~126 MB per job). Symlinks only, so the image carries one node. The consumer must point
# RUNNER_TOOL_CACHE here, as a container job's default /__t is the host's own cache — see README.
COPY --chmod=755 register-node-in-tool-cache.sh /usr/local/bin/register-node-in-tool-cache
RUN register-node-in-tool-cache
