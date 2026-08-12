# syntax=mirror.gcr.io/docker/dockerfile:1
ARG BASE_IMAGE=jclaveau/ubuntu-gha-tools:latest
FROM ${BASE_IMAGE}

ARG DOCKER_GROUP_ID=${DOCKER_GROUP_ID}
# Renovate will update this
ARG DOCKER_VERSION=28.5.2

# Shared base for the dood/dind variants: ubuntu-gha-tools + the Docker CLI & Compose.
# Unpublished intermediate (CI pushes it under the throwaway build tag only).
# No daemon.json here: dood ignores a local daemon (host socket), and dind writes its own.
#
# CLI only, deliberately. dood talks to the HOST daemon over the bind-mounted socket and can never
# run a local one, so docker-ce + containerd.io were pure pull weight in every dood image — and
# time-to-tests for a prebuilt image is almost entirely image pull, so that weight IS the metric.
# dind installs the engine itself, reading this pinned version back off docker-ce-cli.
LABEL org.opencontainers.image.description="ubuntu-gha-tools + Docker CLI & Compose (shared base for dood/dind)"

RUN echo "Create the docker group with GitHub's host GID *before* installing any docker package" \
    && echo "(otherwise the docker-ce postinst dind pulls in creates it with an arbitrary GID," \
    && echo " breaking dood host-socket access)" \
    && sudo groupadd -g ${DOCKER_GROUP_ID} docker \
    \
    && echo "Install the Docker CLI and Compose plugin (no engine — see above)" \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
       | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && sudo apt-get update \
    && VERSION_STRING="$(apt-cache madison docker-ce | awk '{print $3}' | grep -m1 -E "[:=~-]${DOCKER_VERSION}([-~]|$)")" \
    && sudo apt-get install -y \
         docker-ce-cli="$VERSION_STRING" \
         docker-compose-plugin \
    && sudo rm -rf /var/lib/apt/lists/* \
    \
    && sudo usermod -aG docker runner \
    && sudo usermod -aG docker packer

