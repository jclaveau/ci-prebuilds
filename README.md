# Github Actions Container Images

[![Test and Publish](https://github.com/jclaveau/github-action-container-images/actions/workflows/test-and-publish.yml/badge.svg)](https://github.com/jclaveau/github-action-container-images/actions/workflows/test-and-publish.yml)

Prebuilt container images for GitHub Actions that **speed up CI** by shipping common dependencies
preinstalled, while mimicking the default `ubuntu-latest` environment (so `docker compose` and friends
just work). Use one as a job [`container:`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/run-jobs-in-a-container).

## Quickstart

Pull from Docker Hub (`docker.io/jclaveau/<image>`) — drop one into your workflow as the job
`container:`:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container: jclaveau/ubuntu-dood-pnpm:latest
    steps:
      - uses: actions/checkout@v4
      - run: pnpm install --frozen-lockfile
      - run: pnpm test
```

That's it — `pnpm`, `node`, `git`, `docker`, the `runner` user, and the `ubuntu-latest` env are all
already there. For `docker compose` see [dood](dood/README.md) (shared host daemon, lighter) or
[dind](dind/README.md) (isolated daemon, no port/name clashes). For browser tests pick
[playwright](playwright/README.md). For native-addon builds (`node-gyp`) pick the
[`-gyp`](pnpm-gyp/README.md) twin.

## Pick your image

Image names follow `<os>-<mode>[-<layer>][-sudoer]`. Pick one of each axis:

| Axis | Options | Default if unsure |
| --- | --- | --- |
| **OS** | `ubuntu` (24.04, glibc) · `alpine` (3.21, musl, smaller) | `ubuntu` |
| **Mode** | `dood` (host daemon, instant) · `dind` (own daemon, isolated, `--privileged`) | `dood` |
| **Layer** | none · `-node` · `-pnpm` · `-pnpm-gyp` · `-playwright` · `-playwright-gyp` | the highest one you need |
| **Flavor** | hardened (default — no runtime sudo) · `-sudoer` (keeps `NOPASSWD: ALL`) | hardened |

Every combination is published with a `:latest` tag plus a version-pinned tag. Examples on the
current chain (Ubuntu 24.04 / Node 22.12 / pnpm 9.15 / Playwright 1.50):

| Image | `:latest` example | Version-pinned tag example |
| --- | --- | --- |
| `jclaveau/ubuntu-gha-tools` | `:latest` | `:ubuntu24.04` |
| `jclaveau/ubuntu-dood` · `jclaveau/ubuntu-dind` | `:latest` | `:ubuntu24.04` |
| `jclaveau/ubuntu-dood-node` | `:latest` | `:ubuntu24.04-node22.12` |
| `jclaveau/ubuntu-dood-pnpm` | `:latest` | `:ubuntu24.04-node22.12-pnpm9.15` |
| `jclaveau/ubuntu-dood-pnpm-gyp` | `:latest` | `:ubuntu24.04-node22.12-pnpm9.15-gyp` |
| `jclaveau/ubuntu-dood-playwright` | `:latest` | `:ubuntu24.04-node22.12-pnpm9.15-pw1.50` |
| `jclaveau/ubuntu-dood-playwright-gyp` | `:latest` | `:ubuntu24.04-node22.12-pnpm9.15-pw1.50-gyp` |

Swap `ubuntu` → `alpine` and the same shape works (`:alpine3.21-…`). Swap `dood` → `dind` for the
isolated-daemon variant. Append `-sudoer` to the image name (not the tag) for the non-hardened
flavor — e.g. `jclaveau/ubuntu-dood-pnpm-sudoer:latest`.

> `ghcr.io/jclaveau/…:sha-<commit>` tags also exist but are **build intermediates** — the consumer
> contract is Docker Hub `:latest` and the version-pinned tags above.

## Goals
- [x] Prepare images with installed dependencies to speed up CI
- [x] Provide an environment similar to the default `ubuntu-latest` (allowing `docker compose`)

## The big picture

Images are layered — each builds on the previous — and every layer above the base ships in two
**flavors**, `-dood` and `-dind`:

```
ubuntu-gha-tools            GitHub ubuntu-latest mimic (users, env, OS tools; slim — no compiler)
  └─ docker  (internal)     + Docker Engine & Compose
       ├─ dood              shares the host daemon (mounted socket)
       └─ dind              boots its own inner daemon
            then:  node ─┬─ pnpm ─────── playwright          (slim; each in both -dood and -dind)
                         └─ pnpm-gyp ─── playwright-gyp       (+ node-gyp toolchain, for native addons)
```

Variant images are named `<os>-<mode>[-<layer>]` (`os` ∈ {`ubuntu`,`alpine`}, `mode` ∈ {`dood`,`dind`}).
Every layer ships in both OS flavors (e.g. `ubuntu-dood-pnpm` and `alpine-dood-pnpm`); the Alpine images
mirror the Ubuntu dev environment (same accounts, tooling, and bash sugar like `ll`) on musl. The one
exception is **Playwright on Alpine**, which is **Chromium-only** (via the system Chromium package —
Playwright's bundled browsers and Firefox/WebKit have no musl builds). Each layer is documented on its own:

| Image | What it adds | Docs |
| --- | --- | --- |
| `ubuntu-gha-tools` | GitHub `ubuntu-latest` mimic (users, env, OS tools; no compiler) | [README](ubuntu-gha-tools/README.md) |
| `ubuntu-dood` / `ubuntu-dind` | + Docker Engine & Compose (the two flavors) | [dood](dood/README.md) · [dind](dind/README.md) |
| `…-node` | + Node, npm (slim — no compiler) | [README](node/README.md) |
| `…-pnpm` | + pnpm | [README](pnpm/README.md) |
| `…-pnpm-gyp` | + node-gyp toolchain (for native addons) | [README](pnpm-gyp/README.md) |
| `…-playwright` | + Playwright | [README](playwright/README.md) |
| `…-playwright-gyp` | + Playwright on the `-gyp` base | [README](pnpm-gyp/README.md) |

(The `docker` layer is an internal, unpublished base — see [docker/README.md](docker/README.md).)

Each push to `main` runs the full test suite and, **only if every test passes**, publishes `latest`
plus a **version-pinned** tag capturing the OS + tool minors, e.g.
`ubuntu-dood-playwright:ubuntu24.04-node22.12-pnpm9.15-pw1.50`.

## The two flavors

| Aspect | `-dood` (Docker-outside-of-Docker) | `-dind` (true Docker-in-Docker) |
| --- | --- | --- |
| **Usage** | | |
| Docker daemon | Shared **host** daemon | Own inner `dockerd` started per job |
| Socket | Host `/var/run/docker.sock` (GHA bind-mounts it; with `docker run` mount it yourself) | `/var/run/dind.sock` (separate, to avoid the mounted host socket) |
| Required runtime flag | host-socket mount (`-v /var/run/docker.sock:/var/run/docker.sock`) | `--privileged` |
| GHA first step | none — daemon already present | `- run: start-dockerd` (ENTRYPOINT is overridden in container jobs) |
| Client config | default socket | `DOCKER_HOST=unix:///var/run/dind.sock` (set via the container `--env`) |
| Mode detection | `$DOCKER_MODE=dood` (baked at build time) | `$DOCKER_MODE=dind` (baked at build time) — portable steps can branch on `$DOCKER_MODE` without socket-probing |
| Storage driver | the host's | `DOCKER_STORAGE_DRIVER=fuse-overlayfs` (or `vfs` fallback); overlay2 is unstable nested |
| Startup / weight | instant, lighter | ~seconds to boot the daemon, heavier |
| **Effects** | | |
| PWD / bind mounts | sources resolve in the **host** namespace → container paths like `/__w/<repo>/…` don't exist on the host (empty dir / "No such file"); needs host-path rewriting | resolve in the **container's** namespace → `$PWD` / `/__w/…` paths just work |
| Published ports | land on the **host**; reach via `host.docker.internal`; can **conflict** with the host or other jobs sharing the daemon | land on the job container's `localhost`; isolated, no host port conflicts |
| Container names / state | siblings on the shared host daemon → **name/state clashes** and concurrent-job collisions | isolated daemon → no cross-job name/state collisions |
| Image cache | reuses the host's layer cache (fast pulls) | cold per job unless explicitly cached |
| Isolation / security | socket access ≈ control of the host daemon (root-equivalent on the host) | `--privileged` (kernel-level power), but fully isolated state |
| With `act` (local) | uses your local Docker → test containers mix with your own; possible name/port clashes; Docker-Desktop/rootless path quirks | self-contained; if overlay2 nesting fails on your backend set `DOCKER_STORAGE_DRIVER=vfs`; no clashes with your local containers |

See [dood/README.md](dood/README.md) and [dind/README.md](dind/README.md) for the runtime details and
`docker compose` usage examples.

## Hardened (default) and `-sudoer` flavors

Most published images ship in two flavors. The contract is: **pre-installed deps are the value
prop; runtime sudo isn't part of that contract.** Consumers who need ad-hoc system installs at
runtime pull the `-sudoer` variant explicitly.

| Tag | Contract | When to pull |
| --- | --- | --- |
| `<image>:latest` | **Default — hardened.** Runner has **no NOPASSWD sudo** at runtime; build-time sudoers are stripped via a final overlay. | Production CI on a frozen toolkit. |
| `<image>-sudoer:latest` | Same image with `%runner ALL=(ALL) NOPASSWD:ALL` retained. | Dev / experimentation that needs ad-hoc `sudo apt-get install …`. |

The hardened default narrows the blast radius of a compromised transitive dep (a malicious
`pnpm install` postinstall can no longer `sudo -i` to root inside the container). The `-sudoer`
flavor exists so consumers don't have to build a downstream image just to keep the "works like
hosted `ubuntu-latest`" muscle memory.

For local `act --bind` use on untrusted code, prefer **rootless docker** (the host-filesystem
threat isn't solved by the in-container sudo strip; rootless adds the kernel-level guard).

**`dind` exception (narrow sudoers, not broad NOPASSWD)**: the dind family's `start-dockerd`
needs to invoke `sudo dockerd` + `sudo chown root:docker /var/run/dind.sock` + `sudo chmod 660
/var/run/dind.sock` at runtime. The hardened dind images keep a **narrow sudoers entry**
(`/etc/sudoers.d/dind`) allowing **only** those three commands. Everything else (`sudo apt-get
install …`, `sudo -i`, etc.) is denied as on the dood family.

> **Breaking change vs prior `:latest`**: pre-overlay-era `:latest` granted `NOPASSWD: ALL` to
> `runner`. If your workflow runs `sudo apt-get install …` mid-job, switch to
> `<image>-sudoer:latest` (one-line change) or move the install into a downstream Dockerfile.

## Roadmap

See [open issues](https://github.com/jclaveau/github-action-container-images/issues).

## License

MIT
