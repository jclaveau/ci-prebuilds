#!/usr/bin/env bash
# Boot the inner Docker daemon (true DinD).
#   GHA container job:  - run: start-dockerd      (backgrounds daemon, returns)
#   docker run / act:   ENTRYPOINT runs it, then execs CMD (sleep infinity)
set -euo pipefail

# Optional pull-through cache for `act` shards on a dev machine.
# When DIND_REGISTRY_AUTOSTART is truthy AND /var/run/docker.sock is bind-
# mounted from the host, idempotently bring up a `ci-prebuilds-dind-registry`
# container on the HOST docker daemon and point this inner dockerd at it
# via registry-mirrors. All sibling shards race the same docker-run; the
# first wins, the rest no-op via `inspect` + `|| true`.
# Silent fallback paths (warn → no-mirror, dockerd still boots cleanly):
#   - DIND_REGISTRY_AUTOSTART truthy but no host socket present (e.g. on
#     hosted GHA runners that didn't bind it). Autostart is dev-loop-only.
#   - Registry health-probe times out (>15s). The dind still boots; pulls
#     just go direct to upstream.
case "${DIND_REGISTRY_AUTOSTART:-}" in
  1|true|TRUE|yes|YES)
    if [ -S /var/run/docker.sock ]; then
      # Talk to the host daemon via `sudo docker` — never chown/chmod the
      # bind-mounted host socket. The inode is shared with the host, so a
      # chown writes the in-container `docker` GID to the host's inode; if
      # the host's `docker` group has a different GID (it commonly does on
      # non-Debian/Ubuntu hosts, e.g. 130 vs the 118 baked here), the host
      # user gets locked out of their own docker socket until they restore
      # it with `sudo chown root:docker /var/run/docker.sock`. The narrow
      # `/usr/bin/docker` sudoers entry (dind/Dockerfile) keeps this
      # working on the hardened flavor.
      HOST_DOCKER="sudo docker -H unix:///var/run/docker.sock"
      $HOST_DOCKER inspect ci-prebuilds-dind-registry >/dev/null 2>&1 \
        || $HOST_DOCKER run -d --restart=unless-stopped \
             --name ci-prebuilds-dind-registry \
             -p 36000:5000 \
             -v ci-prebuilds-dind-registry-data:/var/lib/registry \
             -e REGISTRY_PROXY_REMOTEURL=https://mirror.gcr.io \
             mirror.gcr.io/library/registry:2 \
           >/dev/null 2>&1 || true
      $HOST_DOCKER start ci-prebuilds-dind-registry >/dev/null 2>&1 || true
      if timeout 15 bash -c 'until curl -fsS http://host.docker.internal:36000/v2/ >/dev/null 2>&1; do sleep 1; done'; then
        : "${DIND_REGISTRY_MIRROR:=http://host.docker.internal:36000}"
        export DIND_REGISTRY_MIRROR
      else
        echo "DIND_REGISTRY_AUTOSTART: registry health-probe timed out; continuing without mirror" >&2
      fi
    else
      echo "DIND_REGISTRY_AUTOSTART set but /var/run/docker.sock not bind-mounted; continuing without mirror" >&2
    fi
    ;;
esac

# Rewrite /etc/docker/daemon.json with a registry-mirrors entry when a mirror
# resolved (autostart above OR explicit user input). Otherwise leave the
# Dockerfile-baked log-only daemon.json untouched.
if [ -n "${DIND_REGISTRY_MIRROR:-}" ]; then
  printf '%s\n' \
    "{\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"},\"registry-mirrors\":[\"${DIND_REGISTRY_MIRROR}\"]}" \
    | sudo tee /etc/docker/daemon.json >/dev/null
fi

# Empty => dockerd auto-selects (overlay2 where supported).
# Override for portability (act on btrfs/zfs/rootless): DOCKER_STORAGE_DRIVER=vfs|overlay2|fuse-overlayfs
driver=""
[ -n "${DOCKER_STORAGE_DRIVER:-}" ] && driver="--storage-driver=${DOCKER_STORAGE_DRIVER}"

# GHA bind-mounts the HOST socket at /var/run/docker.sock into every container job, so the
# inner daemon listens on its own socket and we point clients at it via DOCKER_HOST.
SOCK="${DIND_SOCK:-/var/run/dind.sock}"

# setsid detaches the daemon so it survives the GHA step shell that launched it.
# sudo lets this work whether invoked as runner (ENTRYPOINT) or root (GHA step).
# Log to /tmp: the redirect is opened by the (non-root) caller, then inherited by sudo dockerd.
setsid bash -c "exec sudo dockerd ${driver} --host=unix://${SOCK} </dev/null >/tmp/dockerd.log 2>&1" &
disown 2>/dev/null || true
export DOCKER_HOST="unix://${SOCK}"

timeout 60 bash -c 'until docker info >/dev/null 2>&1; do sleep 1; done' || {
  echo "dockerd failed to start"
  tail -n 50 /tmp/dockerd.log || true
  exit 1
}

sudo chown root:docker "${SOCK}"
sudo chmod 660 "${SOCK}"

# NB: we deliberately do NOT write DOCKER_HOST to $GITHUB_ENV. The daemon does not survive
# across GHA container-job steps, so a persisted DOCKER_HOST would leak a dead socket into the
# job's post-cleanup (`docker exec ...`) and fail the job. Callers that need it across commands
# must `export DOCKER_HOST=unix://${SOCK}` themselves and use it within the same step.

# ENTRYPOINT mode execs the CMD; GHA step mode (no args) returns cleanly.
# NB: must be an `if`, not `[ ... ] && exec` — the latter's failed test would be the
# script's last command and make a no-args invocation exit 1 (fails the GHA step).
if [ "$#" -gt 0 ]; then
  exec "$@"
fi
