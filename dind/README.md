# `{ubuntu,alpine}-dind` — true Docker-in-Docker

The [`docker`](../docker/README.md) base plus an **inner `dockerd`** that boots on its own socket
`/var/run/dind.sock`, giving the container an isolated daemon. See the
[`-dood` vs `-dind`](../README.md#the-two-flavors) comparison.

Ships in both OS flavors (`ubuntu-dind`, `alpine-dind`) with identical behavior — the examples below use
`ubuntu-dind`; swap the prefix for the Alpine build.

Published as `jclaveau/<os>-dind` on Docker Hub. Tags: `:latest` and version-pinned `:<os>`, e.g.
`jclaveau/ubuntu-dind:ubuntu24.04`. Append `-sudoer` to the image name for the non-hardened flavor.

## Usage — Postgres via `docker compose`

Boots its own daemon first; published ports land on the job container, reached via `localhost`:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: jclaveau/ubuntu-dind:latest
      # DOCKER_HOST via --env (not $GITHUB_ENV) so it never leaks to GHA's host-side cleanup
      options: --privileged --env DOCKER_HOST=unix:///var/run/dind.sock
    env:
      DOCKER_STORAGE_DRIVER: fuse-overlayfs   # fast nested CoW; use vfs if your runner lacks /dev/fuse
    steps:
      - run: start-dockerd            # boots the inner daemon (persists across the steps below)
      - uses: actions/checkout@v4
      - run: docker compose -f docker-compose-tests.yaml up -d --wait
      - run: nc -zv localhost 5432
```

## What it adds
- [`start-dockerd`](./start-dockerd.sh) — launches the inner daemon and points clients at it.
- `fuse-overlayfs` (fast nested copy-on-write) and a log-only `daemon.json`. The `ENTRYPOINT` boots the
  daemon automatically under `docker run` / `act`.

## What it implies
- **Runtime**: `--privileged`. In GHA the image `ENTRYPOINT` is overridden, so run `start-dockerd` as the
  **first step** (the daemon then persists across the job's steps).
- Set **`DOCKER_HOST=unix:///var/run/dind.sock` via the container `--env`** — *not* `$GITHUB_ENV`, which
  would leak it to GHA's host-side post-job cleanup and fail the job.
- Pick a nested-friendly **storage driver** with `DOCKER_STORAGE_DRIVER`: `fuse-overlayfs` is fast and
  works on GitHub-hosted runners; `vfs` is the always-works fallback. overlay2 is unstable nested.
- **Bind mounts** resolve in the **container's** namespace → `$PWD` / `/__w/…` just work. **Published
  ports** land on the job container's `localhost`. State is fully **isolated** (no cross-job clashes).
- Heavier (~seconds to boot); the image cache is cold per job unless explicitly cached.

## Auto-shared pull-through cache for `act` shards

`act` matrix shards on a dev machine each spin up their own dind, and each
inner `dockerd` re-pulls the same base images — duplicated bandwidth × shard
count. The dind images can auto-spawn a `registry:2` container on the
HOST docker daemon (named `ci-prebuilds-dind-registry`, port `36000`,
upstream `mirror.gcr.io`) and point every inner dockerd at it via
`registry-mirrors`. First shard to start wins; siblings detect it via
`docker inspect` and no-op.

**One-time setup** — drop into `~/.actrc` (or project-local `./.actrc`):

```
-P ubuntu-latest=ghcr.io/jclaveau/ubuntu-dind:latest
--container-options=--privileged
--container-options=-v /var/run/docker.sock:/var/run/docker.sock
--container-options=--add-host=host.docker.internal:host-gateway
--container-options=-e DIND_REGISTRY_AUTOSTART=1
```

**Per-run cost** — none. `act` (no extra flags). The first invocation
brings up `ci-prebuilds-dind-registry`; every subsequent invocation and
every sharded sibling re-uses it.

**Inspect / wipe** the cache from the host:

```
docker logs ci-prebuilds-dind-registry
docker volume inspect ci-prebuilds-dind-registry-data
docker rm -f ci-prebuilds-dind-registry && docker volume rm ci-prebuilds-dind-registry-data
```

**Explicit endpoint** — set `DIND_REGISTRY_MIRROR=http://your-host:port` to
point the inner dockerd at a registry you run elsewhere. Autostart only
defaults the var when unset.

**Caveats**
- Bind-mounting `/var/run/docker.sock` gives the dind workload host-Docker
  control. Acceptable for `act`-on-dev-machine; **do not enable on hosted
  GHA runners** (autostart silently falls through when the host socket is
  absent, but the bind-mount itself shouldn't be configured there).
- `--add-host=host.docker.internal:host-gateway` is required on Linux for
  the inner dockerd to resolve the host endpoint; harmless on Docker
  Desktop where it's native.
- Autostart silently falls through to no-mirror if (a) `/var/run/docker.sock`
  isn't a socket or (b) the registry takes >15 s to come up. To diagnose,
  read `/tmp/dockerd.log` inside the dind or `docker ps` on the host.

