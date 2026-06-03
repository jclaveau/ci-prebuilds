# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-docker:latest
FROM ${BASE_IMAGE}

# Docker-outside-of-Docker: the docker CLI talks to a shared host daemon via the mounted socket
# (GitHub Actions bind-mounts /var/run/docker.sock into container jobs). Nothing to add over the
# docker base — this is just the published, named variant. (dind is the sibling overlay.)
LABEL org.opencontainers.image.description="Docker-outside-of-Docker variant (uses a shared host daemon via the mounted socket)"

ENV DOCKER_MODE=dood
