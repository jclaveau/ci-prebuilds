# RESOLVED: `ubuntu-dind` is now true DinD (DooD kept as `ubuntu-dood`)

> **Status (2026-05-28):** done in this repo. The DooD behavior was renamed to the `*-dood`
> images; the `*-dind` images now boot an inner `dockerd` via `/usr/local/bin/start-dockerd`
> (see `dind/`). The history below is kept for context.
>
> **Consumer migration (`Hippocast/Planner`):**
> 1. Keep the image name `jclaveau/ubuntu-dind` — it is now *true* DinD (or switch to `pnpm-dind` etc.).
> 2. Drop the host docker-socket mount (`-v /var/run/docker.sock:...`); keep `--privileged`.
> 3. Add a first step `- run: start-dockerd` (ENTRYPOINT is overridden in GHA container jobs). It
>    boots the inner daemon on `/var/run/dind.sock` and writes `DOCKER_HOST` to `$GITHUB_ENV`, so the
>    host socket GHA bind-mounts at `/var/run/docker.sock` is bypassed and later `docker`/`compose`
>    steps target the inner daemon automatically.
> 4. Delete the `resolve_script_dir` plumbing under `apps/cd/docker/scripts/` — bind mounts now
>    resolve in-namespace, so `/__w/...` paths just work.
> 5. If the inner daemon's storage driver fails on a given runner, set `DOCKER_STORAGE_DRIVER=vfs`.

## History

The `ubuntu-dind` image previously ran DooD (the consumer workflow shares the host docker socket). Bind mounts from `docker compose` running inside the job container are forwarded to the **host** docker daemon, which doesn't share the container's filesystem namespace, so paths like `/__w/<repo>/<repo>/...` (the GitHub Actions checkout mount) fail to resolve and the daemon silently creates empty directories under `bind.create_host_path: true`.

## Symptom that surfaced this

`Hippocast/Planner` workflow `.github/workflows/tests-e2e-back.yml`, run on 2026-04-29: the postgres container's `/data` bind mount was empty, so `pnpm db:seed:import:ci` failed with `bash: /data/db_seed_import.sh: No such file or directory`.

## Current consumer-side workaround

`Hippocast/Planner` ships `apps/cd/docker/scripts/_lib.sh` exposing `resolve_script_dir()`, sourced by every shell script in `apps/cd/docker/scripts/`. It re-anchors `SCRIPT_DIR` under `$GITHUB_WORKSPACE` when set, so compose-relative bind mounts resolve to the host-visible mirror (`/home/runner/work/...`) instead of the in-container path (`/__w/...`).

## The proper image-level fix

Make this image run **true DinD**: install `dockerd`/`containerd`/`docker-compose-plugin` and add an entrypoint that boots a daemon before exec-ing the workflow command.

```bash
#!/usr/bin/env bash
# /usr/local/bin/dind-entrypoint.sh
set -euo pipefail

storage_driver=${DOCKER_STORAGE_DRIVER:-vfs}

dockerd \
  --host=unix:///var/run/docker.sock \
  --storage-driver="$storage_driver" \
  --iptables=false \
  >/var/log/dockerd.log 2>&1 &

for i in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done

exec "$@"
```

```Dockerfile
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
COPY dind-entrypoint.sh /usr/local/bin/dind-entrypoint.sh
RUN chmod +x /usr/local/bin/dind-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/dind-entrypoint.sh"]
CMD ["sleep", "infinity"]
```

With the inner daemon, bind mounts evaluate inside the container's namespace — `/__w/...` paths just work, no host-mirror gymnastics.

## When this lands

Revert the consumer-side plumbing in `Hippocast/Planner` (search for `resolve_script_dir` under `apps/cd/docker/scripts/`).

## Trade-offs to weigh before merging

- **Storage driver**: `vfs` is portable but slow; `fuse-overlayfs` is faster but needs FUSE in the runner. Decide before tagging.
- **Image cache**: inner daemon's cache lives at `/var/lib/docker` and is lost between jobs unless the consumer caches it (`actions/cache` on `/var/lib/docker`).
- **Port publishing**: inner daemon manages its own iptables, so `host-gateway`/`--add-host` semantics may differ from DooD.
- **Privileged**: still required. Keep it documented in README.
