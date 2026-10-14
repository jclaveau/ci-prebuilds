# CI-Prebuilds

[![Test and Publish](https://github.com/jclaveau/ci-prebuilds/actions/workflows/test-and-publish.yml/badge.svg)](https://github.com/jclaveau/ci-prebuilds/actions/workflows/test-and-publish.yml)

Speed up [GitHub Actions](https://docs.github.com/en/actions/get-started/quickstart) and [Act](https://nektosact.com) by removing the dep-install steps from your workflows

## Goals
- [x] Speed up CI (Even more relevant at the Agentic era)
- [x] Provide an environment similar to the default `ubuntu-latest` (`docker compose`, `shell aliases`, ...)
- [x] Debugable / Fast using `dind` or `dood`
- [x] Fast and light using the `Alpine` versions
- [x] Easy to extend / Request a specific version
- [x] Easy to revert / Small footprint in the CI workflows

## Quickstart

Pull from Docker Hub (`docker.io/jclaveau/<image>`) or GHCR (`ghcr.io/jclaveau/<image>`, same
tags; no Docker Hub rate limit on GitHub-hosted runners) — drop one into your workflow as the job
`container:`:

```yaml
# Example for acceptance tests
jobs:
  e2e-front:
    runs-on: ubuntu-latest
    container: jclaveau/ubuntu-dood-playwright-gyp:latest
    steps:
      - uses: jclaveau/ci-prebuilds/.github/actions/prepare@v0  # DOCKER_MODE/HOST_ADDRESS defaults + start-dockerd under dind
      - uses: actions/checkout@v4
      - run: pnpm install --frozen-lockfile
      - run: docker compose up -d --wait  # no docker mcr.microsoft.com/playwright
      - run: pnpm exec playwright test    # no `playwright install --with-deps` required
  e2e-back:
    runs-on: ubuntu-latest
    container: jclaveau/ubuntu-dood-pnpm-gyp:latest
    steps:
      - uses: jclaveau/ci-prebuilds/.github/actions/prepare@v0
      - uses: actions/checkout@v4
      - run: pnpm install --frozen-lockfile
      - run: docker compose up -d --wait
      - run: pnpm exec vitest
```


## Images

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

Image names follow `<os>-<mode>[-<layer>][-sudoer]`. Pick one of each axis:

| Axis | Options | Default if unsure |
| --- | --- | --- |
| **OS** | `ubuntu` · `alpine` | `ubuntu` |
| **Mode** | `dood` (faster) · `dind` (isolated) | `dind` |
| **Layer** | none · `-node` · `-pnpm` · `-pnpm-gyp` · `-playwright` · `-playwright-gyp` | your needs |
| **Flavor** | default (no runtime sudo) · `-sudoer` | hardened |

- **`dood` and published ports:** a `dood` job container is a sibling of the containers it starts,
  so a port that `docker compose` publishes is on the runner host, not on the job container's
  `localhost`, and GitHub Actions rejects `--network` in `container.options`. Reach them through
  `$HOST_ADDRESS` (baked per mode), or use `dind`, where published ports land on the job
  container's `localhost`. Job-level `services:` are reached by service name in both modes.
- **`-gyp` or slim:** pick `-gyp` only when a dependency has no prebuilt binary for your libc and
  Node ABI and must compile on install. Many native addons ship musl and glibc prebuilds,
  so slim is often enough; `-gyp` adds about 100 MB to the compressed pull.
- Playwright on Alpine carries **all three browsers** — chromium, firefox and webkit, built from source against musl rather than taken from the system packages.

| Image | What it adds | Docs |
| --- | --- | --- |
| `ubuntu-gha-tools` | GitHub `ubuntu-latest` mimic (users, env, OS tools; no compiler) | [README](ubuntu-gha-tools/README.md) |
| `ubuntu-dood` / `ubuntu-dind` | + Docker Engine & Compose | [dood](dood/README.md) · [dind](dind/README.md) |
| `…-node` | + Node, npm (slim — no compiler) | [README](node/README.md) |
| `…-pnpm` | + pnpm | [README](pnpm/README.md) |
| `…-pnpm-gyp` | + node-gyp toolchain (for native addons) | [README](pnpm-gyp/README.md) |
| `…-playwright` | + Playwright | [README](playwright/README.md) |
| `…-playwright-gyp` | + Playwright on the `-gyp` base | [README](pnpm-gyp/README.md) |

(The `docker` layer is an internal, unpublished base — see [docker/README.md](docker/README.md).)


### Tags
Every combination is published with a `:latest` tag plus a version-pinned tag
`<os><version>[-node<x.y>][-pnpm<x.y>][-pw<x.y>][-gyp][-sudoer]`. The versions move with every
release, so the table shows the shape, not a promise. Examples as of 2026-10-12:

| Image | Version-pinned tag example |
| --- | --- |
| `jclaveau/ubuntu-gha-tools` · `jclaveau/ubuntu-dood` · `jclaveau/ubuntu-dind` | `:ubuntu26.04` |
| `jclaveau/ubuntu-dood-node` | `:ubuntu26.04-node24.21` |
| `jclaveau/ubuntu-dood-pnpm` | `:ubuntu26.04-node24.21-pnpm12.11` |
| `jclaveau/ubuntu-dood-playwright` | `:ubuntu26.04-node24.21-pnpm12.11-pw1.62` |
| `jclaveau/ubuntu-dood-playwright-gyp` | `:ubuntu26.04-node24.21-pnpm12.11-pw1.62-gyp` |
| `jclaveau/alpine-dood-playwright` | `:alpine3.24-node24.18-pnpm12.11-pw1.62` |

To see what `:latest` is right now, read the image's tags on Docker Hub
(`https://hub.docker.com/r/jclaveau/<image>/tags`: the pinned tag pushed with `:latest` shares
its digest) or ask the image itself:

```sh
docker run --rm jclaveau/alpine-dood-playwright:latest playwright --version
```

#### Playwright version must match exactly
Playwright finds its browsers by revision, so your `@playwright/test` must be the same version as
the image's `playwright` (`pw1.62` = 1.62.x); otherwise it fails with `Executable doesn't exist`.
Older Playwright versions are **not** rebuilt on the current Node/pnpm chain. To get one, file a
[build request](https://github.com/jclaveau/ci-prebuilds/issues/new?template=build-request.yml)
with the Node, pnpm and Playwright versions you need:

- **Ubuntu**: any Playwright version; the build installs that version's own browsers.
- **Alpine**: only Playwright versions whose musl browsers were built here. The request derives
  the chromium revision from the requested version, but firefox and webkit stay at the current
  revisions, so pin to the current `pw` minor on Alpine if you need all three browsers.

> `ghcr.io/jclaveau/…:sha-<commit>`, `:edge` and `:buildcache` tags also exist but are **build
> intermediates** — the consumer contract is `:latest` and the version-pinned tags above, on either
> registry.

## Security

- Once every deps are installed you may not require sudo anymore. So sudo is disabled by default
- add `-sudoer` to any image to get sudo back
- For local `act --bind` use on untrusted code, prefer **rootless docker**


## Gains

Median job wall-clock on GitHub-hosted runners, last 4 nightly
[benchmarks](https://github.com/jclaveau/ci-prebuilds/actions/workflows/benchmark-playwright.yml)
(2026-10-10 to 2026-10-14). Baseline = plain `ubuntu-latest` with
`playwright install --with-deps`; official = `mcr.microsoft.com/playwright`:

| Job | chromium only, image vs baseline | all three browsers, image vs baseline |
| --- | --- | --- |
| baseline (VM + install) | 76 s | 202 s |
| official image | 98 vs 76 s (1.29x) | 174 vs 202 s (0.86x) |
| `alpine-dood-playwright` | 76 vs 76 s (1.00x) | 153 vs 202 s (0.76x) |
| `alpine-dind-playwright` | 82 vs 76 s (1.08x) | 149 vs 202 s (0.74x) |
| `ubuntu-dood-playwright` | 78 vs 76 s (1.03x) | 162 vs 202 s (0.80x) |
| `ubuntu-dind-playwright` | 70 vs 76 s (0.92x) | 166 vs 202 s (0.82x) |

With one browser, pulling the image costs about what installing that browser
saves, so there is no gain. The image pays off when the suite runs all three browsers: the Alpine
images bake all three, the Ubuntu images bake chromium only and install firefox and webkit in the job.


## Full control usage

```yaml
jobs:
  e2e-front:
    name: ${{ matrix.mode }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include: # Switch between ci environments to debug or save time
          - mode: dood
            image: jclaveau/ubuntu-dood-playwright-gyp:latest
            options: --volume /var/run/docker.sock:/var/run/docker.sock
          # - mode: dind
          #   image: jclaveau/ubuntu-dind-playwright-gyp:latest
          #   options: --privileged --env DOCKER_HOST=unix:///var/run/dind.sock
          # - mode: vm
          #   image: ""    # empty image → run on the host VM
          #   options: ""
    container:
      image: ${{ matrix.image }}
      options: ${{ matrix.options }}
    steps:
      - uses: jclaveau/ci-prebuilds/.github/actions/prepare@v0  # DOCKER_MODE/HOST_ADDRESS defaults + start-dockerd under dind
      - uses: actions/checkout@v4

      - if: env.DOCKER_MODE == 'vm'
        uses: actions/setup-node@v4
      - if: env.DOCKER_MODE == 'vm'
        uses: pnpm/action-setup@v4
        with:
          run_install: false

      - run: pnpm install --frozen-lockfile
      - run: docker compose up -d --wait

      - if: env.DOCKER_MODE == 'vm'
        name: Install Playwright browsers (vm)
        run: pnpm exec playwright install --with-deps

      - run: pnpm exec playwright test
```

See [the action](.github/actions/prepare/action.yml). Versioning:

- `@v0` — moving tag, advanced manually on compatible action updates
- `@v0.1.0` (immutable) or a commit SHA — full reproducibility
- `@v1` will exist once the repo reaches v1


## Roadmap

See [open issues](https://github.com/jclaveau/ci-prebuilds/issues).

## License

MIT
