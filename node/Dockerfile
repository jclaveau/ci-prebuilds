# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood:latest
FROM ${BASE_IMAGE}

# Renovate will update this
ARG NODE_VERSION=26.13.0


LABEL org.opencontainers.image.description="Node + npm (slim, no compiler) in Ubuntu based DinD as Github Actions Container"


# Node + npm only — no node-gyp toolchain here (the base gha-tools no longer ships a compiler). Native
# addon builds use the `-gyp` variant ({os}-{mode}-pnpm-gyp), which adds build-essential. See README.
RUN echo "Install Node.js (NodeSource)" \
    && sudo curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION%%.*}.x | sudo bash - \
    && sudo apt-get install -y nodejs \
    && sudo rm -rf /var/lib/apt/lists/*

# A node in /usr/bin is invisible to `actions/setup-node`, which would download another one over it
# (~56 MiB per job). Symlinks only, so the image carries one node. Read where the lookup hits
# before relying on it: a GHA container job reads the HOST cache on /__t, not this one — see README.
COPY --chmod=755 register-node-in-tool-cache.sh /usr/local/bin/register-node-in-tool-cache
RUN register-node-in-tool-cache

# The manifest `assert-prebuilt-tools-in-use` reads at the end of a consumer job: one row per
# tool this image prebuilt, so a step that puts its own node or pnpm first on PATH
# (actions/setup-node, pnpm/action-setup) can be named rather than silently paid for twice.
# Lives at the node layer because that is the first one with a tool worth asserting, and
# because node/ is one build context for both OS flavors — the pnpm, -gyp and playwright
# layers inherit both scripts and only add their own `record-image-tool` call.
COPY --chmod=755 record-image-tool.sh /usr/local/bin/record-image-tool
COPY --chmod=755 assert-prebuilt-tools-in-use.sh /usr/local/bin/assert-prebuilt-tools-in-use
RUN sudo record-image-tool node
