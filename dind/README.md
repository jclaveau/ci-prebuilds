# `{ubuntu,alpine}-dind` — true Docker-in-Docker

The [`docker`](../docker/README.md) base plus an **inner `dockerd`** that boots on its own socket
`/var/run/dind.sock`, giving the container an isolated daemon. For the shared-host-daemon
alternative, see [`-dood`](../dood/README.md).

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
- `DOCKER_MODE=dind` env var (sibling [`-dood`](../dood/README.md) ships `=dood`) so portable workflow
  steps can branch on `$DOCKER_MODE` without socket / `pgrep` probing.
- `HOST_ADDRESS=127.0.0.1` env var (sibling [`-dood`](../dood/README.md) ships `=host.docker.internal`)
  — the address where compose-published services are reachable from inside the runner. Literal
  `127.0.0.1` (not `localhost`) forces ipv4 to dodge connection-refused on stacks that resolve
  `localhost` to `::1`.
- `DOCKER_STORAGE_DRIVER=fuse-overlayfs` env var baked in — start-dockerd uses this by default so
  consumers don't have to set it. Override with `--env DOCKER_STORAGE_DRIVER=vfs` (always works,
  slower) or `=overlay2` (parent FS must support overlay-on-overlay) on backends without `/dev/fuse`.

## What it implies
- **Runtime**: `--privileged`. In GHA the image `ENTRYPOINT` is overridden, so run `start-dockerd` as the
  **first step** (the daemon then persists across the job's steps).
- Set **`DOCKER_HOST=unix:///var/run/dind.sock` via the container `--env`** — *not* `$GITHUB_ENV`, which
  would leak it to GHA's host-side post-job cleanup and fail the job.
- **Storage driver** defaults to `fuse-overlayfs` (`ENV` baked at build time) — fast on
  GitHub-hosted runners. Override with `--env DOCKER_STORAGE_DRIVER=vfs` (always-works fallback)
  when `/dev/fuse` isn't available; overlay2 is unstable nested.
- **Bind mounts** resolve in the **container's** namespace → `$PWD` / `/__w/…` just work. **Published
  ports** land on the job container's `localhost`.
- **Isolation / security**: `--privileged` grants kernel-level capabilities, but state is fully
  **isolated** — no cross-job name/port collisions (the cost [`-dood`](../dood/README.md) pays for
  being lighter).
- Heavier (~seconds to boot); the image cache is cold per job unless explicitly cached.
- **With `act` (local)**: self-contained — no clashes with your local containers (unlike
  [`-dood`](../dood/README.md), which mixes test containers with your host's). If overlay2 nesting
  fails on your backend, override `--env DOCKER_STORAGE_DRIVER=vfs`.

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
- Autostart never mutates the host socket. It talks to the host daemon via
  `sudo docker -H unix:///var/run/docker.sock …` inside the container — no
  `chown` / `chmod` on the bind-mounted inode. (Earlier versions chowned it
  to the in-container `docker` GID, which locked host users out when the
  host's docker GID differed from the in-container one. Guarded by
  `tests/act/smoke-dind-registry-autostart.yml`'s perms-snapshot diff.)
- `--add-host=host.docker.internal:host-gateway` is required on Linux for
  the inner dockerd to resolve the host endpoint; harmless on Docker
  Desktop where it's native.
- Autostart silently falls through to no-mirror if (a) `/var/run/docker.sock`
  isn't a socket or (b) the registry takes >15 s to come up. To diagnose,
  read `/tmp/dockerd.log` inside the dind or `docker ps` on the host.

