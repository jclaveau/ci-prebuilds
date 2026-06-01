# syntax=docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-gha-tools:latest
FROM ${BASE_IMAGE}

ARG DOCKER_GROUP_ID=${DOCKER_GROUP_ID}
# Renovate will update this
ARG DOCKER_VERSION=28.5.1

# Shared base for the dood/dind variants: ubuntu-gha-tools + Docker Engine & Compose.
# Unpublished intermediate (CI pushes it under the throwaway build tag only).
# No daemon.json here: dood ignores a local daemon (host socket), and dind writes its own.
LABEL org.opencontainers.image.description="ubuntu-gha-tools + Docker Engine & Compose (shared base for dood/dind)"

RUN echo "Create the docker group with GitHub's host GID *before* installing docker-ce" \
    && echo "(otherwise the docker-ce postinst creates it with an arbitrary GID, breaking dood host-socket access)" \
    && sudo groupadd -g ${DOCKER_GROUP_ID} docker \
    \
    && echo "Install Docker Engine and Compose" \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
       | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && sudo apt-get update \
    && VERSION_STRING="$(apt-cache madison docker-ce | awk '{print $3}' | grep -m1 -E "[:=~-]${DOCKER_VERSION}([-~]|$)")" \
    && sudo apt-get install -y \
         docker-ce="$VERSION_STRING" \
         docker-ce-cli="$VERSION_STRING" \
         docker-compose-plugin \
         containerd.io \
         iptables \
    && sudo rm -rf /var/lib/apt/lists/* \
    \
    && sudo usermod -aG docker runner \
    && sudo usermod -aG docker packer

VOLUME /var/lib/docker
