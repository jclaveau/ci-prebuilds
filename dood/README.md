# `{ubuntu,alpine}-dood` — Docker-outside-of-Docker

The [`docker`](../docker/README.md) base used with a **shared host daemon**: the `docker` CLI talks to
the host's `/var/run/docker.sock`. GitHub Actions bind-mounts that socket into every container job; with
`docker run` you mount it yourself. See the [`-dood` vs `-dind`](../README.md#the-two-flavors) comparison.

Ships in both OS flavors (`ubuntu-dood`, `alpine-dood`) with identical behavior — the examples below use
`ubuntu-dood`; swap the prefix for the Alpine build.

Published as `jclaveau/<os>-dood` on Docker Hub. Tags: `:latest` and version-pinned `:<os>`, e.g.
`jclaveau/ubuntu-dood:ubuntu24.04`. Append `-sudoer` to the image name for the non-hardened flavor.

## What it implies
- **Runtime**: mount the host socket (`-v /var/run/docker.sock:/var/run/docker.sock`); on GHA it's already
  present. Lighter and instant (no daemon to boot).
- **Bind mounts** resolve in the **host** filesystem — container paths like `/__w/<repo>/…` don't exist
  on the host (you get an empty dir / "No such file"), so they need host-path rewriting.
- **Published ports** land on the **host**; reach them via `host.docker.internal`; they can **clash**
  with the host or with other jobs sharing the daemon.
- **Container names / state** are siblings on the shared daemon → cross-job name/state collisions.
- Reuses the host's **layer cache** (fast pulls). Socket access ≈ **root on the host**.
- With **`act`** (local): uses your local Docker, so test containers mix with your own (possible
  name/port clashes).

## Usage — Postgres via `docker compose`

Uses the host daemon (GHA bind-mounts its socket); published ports land on the host, reached via
`host.docker.internal`:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: jclaveau/ubuntu-dood:latest
      options: --privileged --add-host=host.docker.internal:host-gateway
    steps:
      - uses: actions/checkout@v4
      - run: docker compose -f docker-compose-tests.yaml up -d --wait
      - run: nc -zv host.docker.internal 5432
```

## Running locally with `act --bind`

The image's `USER` is `runner` (**UID 1001**) to mirror GitHub's `ubuntu-latest`. Under
`act --bind` the workspace is bind-mounted (not copied), so files the job creates in `$PWD`
land on **the host owned by 1001** — friction if your host UID is 1000.

Make step processes run as the host user by forwarding `--user` to `docker create`, plus
joining the `runner` group (GID 1001) so `sudo` and `/home/runner` writes still work:

```bash
act --bind \
    --container-options "--user $(id -u):$(id -g) --group-add 1001 -e HOME=/home/runner" \
    -P ubuntu-latest=jclaveau/ubuntu-dood:latest \
    -W .github/workflows/<your-workflow>.yml
```

Opt-in by construction — the published image keeps `USER runner`, only the consumer's local
invocation overrides it. The GHA / `container:` path above is untouched.

Why each flag:
- `--user $UID:$GID` — files created in `$PWD` land on the host owned by the host user.
- `--group-add 1001` — process gets `runner` as a supplementary group → `%runner`
  sudoers rule matches (sudo works); `/home/runner` (group-writable, `0775`) accepts
  writes to `~/.cache` / `~/.npm` / `~/.config`; `/opt/hostedtoolcache` (`2775`, SGID +
  g+w) accepts `setup-node` / `setup-python` / … writes, with new subdirs inheriting
  group `runner`.
- `-e HOME=/home/runner` — sets `$HOME` explicitly so tools that read the env (git, npm,
  pnpm, docker, playwright, …) resolve `~` cleanly without an `/etc/passwd` entry for the
  caller's UID. Tools that call `getpwuid()` directly may still log a cosmetic warning;
  none we exercise break.

The `test-dood-dind-act` CI job pins this recipe against both `ubuntu-dood` and
`alpine-dood` (workspace ownership + `sudo true` + `$HOME` write + `$RUNNER_TOOL_CACHE`
subdir write asserted) so a future act/base-image change can't silently break it.

### Host UIDs without a passwd entry (advanced)

`sudo`, `whoami`, and tools using `getpwuid()` refuse / warn when the host UID has no
`/etc/passwd` entry in the image (only `0`, `1000`, `1001` do). For arbitrary UIDs the
image ships `nss_wrapper` and a helper script — opt in from your workflow:

```yaml
- name: nss_wrapper passwd synthesis
  run: |
    . /usr/local/bin/nss-wrapper-setup
    { echo "LD_PRELOAD=$LD_PRELOAD"
      echo "NSS_WRAPPER_PASSWD=$NSS_WRAPPER_PASSWD"
      echo "NSS_WRAPPER_GROUP=$NSS_WRAPPER_GROUP"
    } >> "$GITHUB_ENV"
```

Subsequent steps inherit the env via `$GITHUB_ENV`. Fixes `whoami`, `$HOME`-via-passwd,
and `getpwuid()` consumers (npm, git, login shells). **Does NOT fix `sudo`** — sudo is
setuid and glibc strips `LD_PRELOAD` for setuid binaries (`AT_SECURE`). Pinning sudo
too would require adding the wrapper to `/etc/ld.so.preload` system-wide (a global
preload affecting every binary on every container start); out of scope here.
