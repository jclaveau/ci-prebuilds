# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood-node:latest
FROM ${BASE_IMAGE}

# Renovate will update this (keep in sync with pnpm/Dockerfile)
ARG PNPM_VERSION=12.5.1

# The node-gyp variant: pnpm + the C/C++ toolchain that the base gha-tools deliberately drops. Built as a
# SIBLING of the slim `pnpm` layer (both FROM node) so the two chains build in parallel. The pnpm install
# mirrors pnpm/Dockerfile — the repo re-installs per chain on purpose (symmetric graph over dedup). Use
# this (over slim {os}-{mode}-pnpm) when `pnpm install` compiles native addons; python3 comes from gha-tools.
LABEL org.opencontainers.image.description="pnpm + node-gyp build toolchain (build-essential) for native addons, Ubuntu based"

ENV PNPM_HOME="/home/runner/.local/share/pnpm"
# pnpm 11 moved the global bin dir to $PNPM_HOME/bin and made "not in PATH"
# a hard error instead of a warning, so `pnpm install -g` in any derived
# image fails without it. The bare dir stays for a PNPM_VERSION pinned to 10.
ENV PATH="${PATH}:${PNPM_HOME}:${PNPM_HOME}/bin"

RUN echo "Install PNPM via the npm registry (SHA512-checked tarballs)" \
    && sudo npm install -g pnpm@${PNPM_VERSION}

RUN echo "Install the node-gyp toolchain (build-essential) for native addon compilation" \
    && sudo apt-get update \
    && sudo apt-get install -y --no-install-recommends build-essential \
    && sudo rm -rf /var/lib/apt/lists/*

# TEMP: python3-setuptools provides a vendored distutils shim (setuptools >=60)
# so legacy node-gyp <10 (which imports `distutils.version.StrictVersion`) keeps
# working under Python 3.12, which dropped stdlib distutils (PEP 632). Remove
# once downstream consumers (Planner) bump node-gyp to >=10.
RUN echo "TEMP: distutils shim for legacy node-gyp <10 on Python 3.12" \
    && sudo apt-get update \
    && sudo apt-get install -y --no-install-recommends python3-setuptools \
    && sudo rm -rf /var/lib/apt/lists/*

# `share-dir-with-runner-group <dir>...`: makes an image-baked state dir under
# /home/runner writable by the `runner` GROUP, so a container run under an
# arbitrary host UID — the `act --bind --user $(id -u):$(id -g) --group-add 1001`
# recipe in dood/README.md — can still create entries in it. chown is not an
# option: the consumer's UID is unknown at build time. Setgid keeps entries
# created later in group `runner`, same shape as gha-tools' `chmod 2775
# /opt/hostedtoolcache`. Directories only — chmod-ing the baked files would copy
# every one of them up into this layer. Inlined here (vs COPY) because the build
# context is this per-image dir, not the repo root — kept identical to
# pnpm/Dockerfile.
RUN <<'EOF' sudo bash
cat > /usr/local/bin/share-dir-with-runner-group <<'SCRIPT'
#!/bin/sh
set -e
for dir in "$@"; do
  mkdir -p "$dir"
  find "$dir" -type d -exec chown runner:runner {} + -exec chmod 2775 {} +
  # An ancestor `mkdir -p` created as root only has to be traversable, not
  # group-writable: nothing is ever created directly in ~/.local/share. Leave a
  # dir an earlier argument already shared (-perm -2020) alone, or `$PNPM_HOME/bin`
  # would walk up and strip the group write `$PNPM_HOME` was just given.
  parent=$(dirname "$dir")
  while [ "$parent" != /home/runner ] && [ "$parent" != / ]; do
    chown runner:runner "$parent"
    [ -n "$(find "$parent" -maxdepth 0 -perm -2020)" ] || chmod 0755 "$parent"
    parent=$(dirname "$parent")
  done
done
SCRIPT
chmod 0755 /usr/local/bin/share-dir-with-runner-group
EOF

# pnpm writes its global tree, store and config as the user running the job, so
# all three have to be group-shared before a non-`runner` UID can install
# anything. The playwright layer re-runs this for the dirs it adds.
RUN sudo share-dir-with-runner-group \
        "${PNPM_HOME}" "${PNPM_HOME}/bin" \
        /home/runner/.cache/pnpm \
        /home/runner/.config/pnpm
