# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-dood-node:latest
FROM ${BASE_IMAGE}

# Renovate will update this
ARG PNPM_VERSION=12.5.1


# LABEL maintainer="your-email@example.com"
# LABEL org.opencontainers.image.source="https://github.com/jclaveau/docker-images"
LABEL org.opencontainers.image.description="pnpm on top of Node in Ubuntu based DinD as Github Actions Container"


# https://github.com/pnpm/pnpm/issues/4495#issuecomment-1317831712
ENV PNPM_HOME="/home/runner/.local/share/pnpm"
# pnpm 11 moved the global bin dir to $PNPM_HOME/bin and made "not in PATH"
# a hard error instead of a warning, so `pnpm install -g` in any derived
# image fails without it. The bare dir stays for a PNPM_VERSION pinned to 10.
ENV PATH="${PATH}:${PNPM_HOME}:${PNPM_HOME}/bin"


RUN echo "Install PNPM via the npm registry (SHA512-checked tarballs)" \
    && sudo npm install -g pnpm@${PNPM_VERSION}

# `share-dir-with-runner-group <dir>...`: makes an image-baked state dir under
# /home/runner writable by the `runner` GROUP, so a container run under an
# arbitrary host UID — the `act --bind --user $(id -u):$(id -g) --group-add 1001`
# recipe in dood/README.md — can still create entries in it. chown is not an
# option: the consumer's UID is unknown at build time. Setgid keeps entries
# created later in group `runner`, same shape as gha-tools' `chmod 2775
# /opt/hostedtoolcache`. Directories only — chmod-ing the baked files would copy
# every one of them up into this layer. Inlined here (vs COPY) because the build
# context is this per-image dir, not the repo root — kept identical to
# pnpm-gyp/Dockerfile.
RUN <<'EOF' sudo bash
cat > /usr/local/bin/share-dir-with-runner-group <<'SCRIPT'
#!/bin/sh
set -e
for dir in "$@"; do
  mkdir -p "$dir"
  find "$dir" -type d -exec chown runner:runner {} + -exec chmod 2775 {} +
  parent=$(dirname "$dir")
  while [ "$parent" != /home/runner ] && [ "$parent" != / ]; do
    chown runner:runner "$parent"
    chmod 2775 "$parent"
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
