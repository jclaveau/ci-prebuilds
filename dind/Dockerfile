# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-docker:latest
FROM ${BASE_IMAGE}

# True DinD variant: boots an inner dockerd instead of relying on a shared host socket.
# Built on the docker base (and on each *-dood-<layer>) via the BASE_IMAGE build-arg.
LABEL org.opencontainers.image.description="True DinD variant (boots an inner dockerd) of the *-dood images"

ENV DOCKER_MODE=dind
# DinD's inner dockerd publishes services on the runner container's loopback.
# Literal 127.0.0.1 (not "localhost") forces ipv4 — connection-refused errors
# have historically surfaced when stacks resolved localhost to ::1.
ENV HOST_ADDRESS=127.0.0.1

COPY start-dockerd.sh /usr/local/bin/start-dockerd
RUN sudo chmod 0755 /usr/local/bin/start-dockerd

# Narrow sudoers for the start-dockerd init dance. Survives the broad-NOPASSWD
# strip in harden/Dockerfile, so runner can still bootstrap the inner daemon on
# the hardened flavor — but `sudo apt-get install …` etc. stay denied.
# `visudo -c` validates the file at build time; a typo would otherwise break
# ALL sudo at runtime.
# `/usr/bin/docker` (with no arg restriction) is for the DIND_REGISTRY_AUTOSTART
# path in start-dockerd.sh: it talks to the bind-mounted HOST docker socket via
# `sudo docker -H unix:///var/run/docker.sock …`. We deliberately do NOT chown
# the bind-mounted host socket (the inode is shared with the host; chowning it
# writes the in-container `docker` GID to the host's inode and locks the host
# user out of their own socket when the host's docker GID differs).
RUN echo "runner ALL=(root) NOPASSWD: /usr/sbin/dockerd, /usr/bin/chown root\:docker /var/run/dind.sock, /usr/bin/chmod 660 /var/run/dind.sock, /usr/bin/docker, /usr/bin/tee /etc/docker/daemon.json" \
      | sudo install -m 0440 /dev/stdin /etc/sudoers.d/dind \
    && sudo visudo -c -f /etc/sudoers.d/dind

# fuse-overlayfs: overlay-like copy-on-write storage that works nested (overlay2-on-overlayfs is
# unstable in GHA container jobs) and is far faster/leaner than vfs. Needs /dev/fuse at runtime,
# which GitHub-hosted runners expose under --privileged.
RUN sudo apt-get update \
    && sudo apt-get install -y --no-install-recommends fuse-overlayfs \
    && sudo rm -rf /var/lib/apt/lists/*

# Default the inner dockerd's storage driver to fuse-overlayfs (rationale on the
# install line above). Consumers on a backend without /dev/fuse (some rootless / btrfs
# / zfs setups under `act`) override with `--env DOCKER_STORAGE_DRIVER=vfs` (always
# works) or `=overlay2` (only when the parent FS supports overlay-on-overlay).
ENV DOCKER_STORAGE_DRIVER=fuse-overlayfs

# Log options only; storage-driver is passed as a CLI flag by start-dockerd.sh
# (reading $DOCKER_STORAGE_DRIVER, defaulted above to fuse-overlayfs). The docker
# base intentionally ships no daemon.json.
RUN sudo mkdir -p /etc/docker \
    && echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' \
    | sudo tee /etc/docker/daemon.json >/dev/null

# Needs --privileged at runtime. In GHA container jobs the ENTRYPOINT is overridden,
# so run `start-dockerd` as the first step instead.
ENTRYPOINT ["start-dockerd"]
CMD ["sleep", "infinity"]
