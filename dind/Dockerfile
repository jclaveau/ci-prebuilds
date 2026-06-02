# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-docker:latest
FROM ${BASE_IMAGE}

# True DinD variant: boots an inner dockerd instead of relying on a shared host socket.
# Built on the docker base (and on each *-dood-<layer>) via the BASE_IMAGE build-arg.
LABEL org.opencontainers.image.description="True DinD variant (boots an inner dockerd) of the *-dood images"

COPY start-dockerd.sh /usr/local/bin/start-dockerd
RUN sudo chmod 0755 /usr/local/bin/start-dockerd

# Narrow sudoers for the start-dockerd init dance. Survives the broad-NOPASSWD
# strip in harden/Dockerfile, so runner can still bootstrap the inner daemon on
# the hardened flavor — but `sudo apt-get install …` etc. stay denied.
# `visudo -c` validates the file at build time; a typo would otherwise break
# ALL sudo at runtime.
RUN echo "runner ALL=(root) NOPASSWD: /usr/sbin/dockerd, /usr/bin/chown root\:docker /var/run/dind.sock, /usr/bin/chmod 660 /var/run/dind.sock" \
      | sudo install -m 0440 /dev/stdin /etc/sudoers.d/dind \
    && sudo visudo -c -f /etc/sudoers.d/dind

# fuse-overlayfs: overlay-like copy-on-write storage that works nested (overlay2-on-overlayfs is
# unstable in GHA container jobs) and is far faster/leaner than vfs. Needs /dev/fuse at runtime,
# which GitHub-hosted runners expose under --privileged. Select it via DOCKER_STORAGE_DRIVER.
RUN sudo apt-get update \
    && sudo apt-get install -y --no-install-recommends fuse-overlayfs \
    && sudo rm -rf /var/lib/apt/lists/*

# The inner daemon owns its storage-driver choice (auto-detect by default, or the
# DOCKER_STORAGE_DRIVER override at runtime), so we set only log options here and leave the
# storage-driver unset (the docker base intentionally ships no daemon.json).
RUN sudo mkdir -p /etc/docker \
    && echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' \
    | sudo tee /etc/docker/daemon.json >/dev/null

# Needs --privileged at runtime. In GHA container jobs the ENTRYPOINT is overridden,
# so run `start-dockerd` as the first step instead.
ENTRYPOINT ["start-dockerd"]
CMD ["sleep", "infinity"]
