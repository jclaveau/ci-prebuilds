# syntax=mirror.gcr.io/docker/dockerfile:1
#
# Strip-at-end hardening overlay. Runs LAST in the build pipeline, after every
# downstream layer is built with the runner sudoers still present (so each
# layer's `sudo apt-get install …` / `sudo apk add …` works at build time).
# This overlay removes the runner sudoers entry so the FINAL published image
# has no runtime sudo grant for the runner user.
#
# Published as `<image>:latest` (default). The unmodified build-chain image is
# also published as `<image>-sudoer:latest` for consumers who need ad-hoc
# runtime sudo (rare with the pre-installed toolkits).
#
# Built once per hardenable parent image via the same `build-layer` composite
# action; the parent is selected by the BASE_IMAGE build-arg, so this single
# file parameterizes the whole hardened matrix.
#
# Not applied to dind layers: start-dockerd.sh invokes `sudo dockerd`/`chown`/
# `chmod` at runtime, which requires runner sudo. Hardened dind needs a narrow
# per-binary sudoers entry in dind/Dockerfile — tracked as a follow-up.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.description="Hardened flavor: runner has no runtime sudo grant. Pre-installed deps are the contract. For ad-hoc system installs use <image>-sudoer:latest."

USER root
RUN rm -f /etc/sudoers.d/runner
USER runner
