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

Pull from Docker Hub (`docker.io/jclaveau/<image>`) — drop one into your workflow as the job
`container:`:

```yaml
# Example for acceptance tests
jobs:
  e2e-front:
    runs-on: ubuntu-latest
    container: jclaveau/ubuntu-dood-playwright-gyp:latest
    steps:
      - uses: actions/checkout@v4
      - run: pnpm install --frozen-lockfile
      - run: docker compose up -d --wait  # no docker mcr.microsoft.com/playwright
      - run: pnpm exec playwright test    # no `playwright install --with-deps` required
  e2e-back:
    runs-on: ubuntu-latest
    container: jclaveau/ubuntu-dood-pnpm-gyp:latest
    steps:
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

- **One exception**: Playwright on Alpine is **Chromium-only** for now (using a --shell-only Chromium).

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
Every combination is published with a `:latest` tag plus a version-pinned tag. Examples on the
current chain (Ubuntu 24.04 / Node 22.12 / pnpm 9.15 / Playwright 1.50):

| Image | `:latest` example | Version-pinned tag example |
| --- | --- | --- |
| `jclaveau/ubuntu-gha-tools` | `:latest` | `:ubuntu24.04` |
| `jclaveau/ubuntu-dood` · `jclaveau/ubuntu-dind` | `:latest` | `:ubuntu24.04` |
| `jclaveau/ubuntu-dood-node` | `:latest` | `:ubuntu24.04-node22.12` |
| `jclaveau/ubuntu-dood-pnpm` | `:latest` | `:ubuntu24.04-node22.12-pnpm9.15` |
| `jclaveau/ubuntu-dood-playwright` | `:latest` | `:ubuntu24.04-node22.12-pnpm9.15-pw1.50` |
| `jclaveau/ubuntu-dood-playwright-gyp` | `:latest` | `:ubuntu24.04-node22.12-pnpm9.15-pw1.50-gyp` |


> `ghcr.io/jclaveau/…:sha-<commit>` tags also exist but are **build intermediates** — the consumer
> contract is Docker Hub `:latest` and the version-pinned tags above.

## Security

- Once every deps are installed you may not require sudo anymore. So sudo is disabled by default
- add `-sudoer` to any image to get sudo back
- For local `act --bind` use on untrusted code, prefer **rootless docker**


## Gains

See [The last benchmarks](https://github.com/jclaveau/ci-prebuilds/actions/workflows/benchmark-playwright.yml).


## Roadmap

See [open issues](https://github.com/jclaveau/ci-prebuilds/issues).

## License

MIT
