# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-docker:latest
FROM ${BASE_IMAGE}

# Docker-outside-of-Docker: the docker CLI talks to a shared host daemon via the mounted socket
# (GitHub Actions bind-mounts /var/run/docker.sock into container jobs). Nothing to add over the
# docker base — this is just the published, named variant. (dind is the sibling overlay.)
LABEL org.opencontainers.image.description="Docker-outside-of-Docker variant (uses a shared host daemon via the mounted socket)"

ENV DOCKER_MODE=dood
# DooD shares the host docker daemon; compose services published on the host
# network reach the runner container via host.docker.internal (host-gateway
# alias). Consumers read $HOST_ADDRESS instead of branching on $DOCKER_MODE.
ENV HOST_ADDRESS=host.docker.internal

# Narrow sudoers so a job can join the group of the socket it was actually handed. The
# host socket keeps the HOST's gid in a container job, and the images can only bake the
# gids GitHub has shipped so far (docker/Dockerfile's DOCKER_HOST_GROUP_IDS) — gid 111
# appeared on 2026-11-21 and locked uid 1001 out of every docker call. The entrypoint
# cannot fix it (the runner replaces it with `tail -f /dev/null`), but a STEP can:
# `docker exec` resolves the user's supplementary groups from /etc/group at every exec,
# so a group the prepare action joins in its own step reaches all the later ones.
# Two binaries only, and the entry survives the broad-NOPASSWD strip in harden/Dockerfile
# because of its own file name — `sudo apk add …` stays denied on the hardened flavor.
# Paths are resolved here, not written literally: sudo matches a rule against the absolute
# path it resolves the command to, so a rule naming a path the binary does not occupy never
# matches, silently (groupadd and usermod are /usr/sbin on both families today). The `-x`
# guard makes a future package move fail the build instead of handing back a job whose
# docker calls all read "permission denied".
RUN GROUPADD="$(command -v groupadd)" \
    && USERMOD="$(command -v usermod)" \
    && for p in "$GROUPADD" "$USERMOD"; do [ -x "$p" ] || { echo "sudoers: '$p' is not an executable path"; exit 1; }; done \
    && echo "runner ALL=(root) NOPASSWD: ${GROUPADD}, ${USERMOD}" \
      | sudo install -m 0440 /dev/stdin /etc/sudoers.d/docker-host-gid \
    && sudo visudo -c -f /etc/sudoers.d/docker-host-gid
