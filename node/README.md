# node layer — `{ubuntu,alpine}-{dood,dind}-node`

Adds **Node.js + npm** (slim — no compiler) on top of a [`-dood`](../dood/README.md) /
[`-dind`](../dind/README.md) base.

## Usage

Published as `jclaveau/<os>-<mode>-node` on Docker Hub — four variants:
`jclaveau/ubuntu-dood-node`, `…-ubuntu-dind-node`, `…-alpine-dood-node`, `…-alpine-dind-node`.
Tags: `:latest` and version-pinned `:<os>-<node-minor>`, e.g.
`jclaveau/ubuntu-dood-node:ubuntu24.04-node22.12`. Append `-sudoer` to the image name for the
non-hardened flavor.

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container: jclaveau/ubuntu-dood-node:latest
    steps:
      - uses: actions/checkout@v4
      - run: node -v && npm ci
      - run: npm test
```

For `pnpm` use [`-pnpm`](../pnpm/README.md); for native-addon builds use
[`-pnpm-gyp`](../pnpm-gyp/README.md).

## Keeping `actions/setup-node`

The installed node is registered in the runner tool-cache layout
(`/opt/hostedtoolcache/node/<version>/<arch>`, symlinks to the installed node — no second node in
the image), which is the only place `actions/setup-node` looks before it downloads one. Ask for a
range, as `tc.find` only semver-matches a non-explicit spec and the installed minor floats with
the image's node:

```yaml
      - uses: actions/setup-node@v4
        with:
          node-version: 24.x   # a range: the installed minor floats, so an exact version misses
```

Miss the lookup and `setup-node` installs the `actions/node-versions` build, which is glibc-only:
on Ubuntu a redundant ~56 MiB download per job, on Alpine a node that cannot run — and the step
itself still exits 0, so the failure surfaces one step later as
`cannot execute: required file not found`.

**The lookup hits where the tool cache is the image's own**: `act` with the image as the runner
(`-P ubuntu-latest=<image>`, asserted by `tests/act/smoke-node-setup-node.yml`), a plain
`docker run`, or a self-hosted runner whose process lives in the image.

**It cannot hit in a GitHub Actions container job.** GitHub injects its own `RUNNER_TOOL_CACHE`
([`gha-tools`](../ubuntu-gha-tools/README.md#what-it-implies)) — the *host* runner's cache,
bind-mounted on `/__t` — and overwrites every `RUNNER_*` the workflow sets, per step. So an
Alpine container job still resolves the host's glibc node, and no image-side registration can
change that; registering from a job step would instead write container paths into the host cache
every later job on that runner would read.

`register-node-in-tool-cache` stays on the image, so a job that upgrades node in place can
re-register it — on a `-sudoer` tag, since replacing node needs root and the published tags are
hardened without `sudo`.

## What it adds
- **Node.js + npm** — on Ubuntu from NodeSource (the major comes from the `NODE_VERSION` build-arg); on
  Alpine nodejs.org's musl build of exactly `NODE_VERSION`, from
  [unofficial-builds](https://unofficial-builds.nodejs.org/), in `/usr/local` (#351). Not Alpine's
  `nodejs` package: that one is built without node's code cache and against 10 system libraries,
  and paid for it on every start (`node -e 0` 82 vs 52 ms CPU, #350).
- **Alpine: a pinned checksum per node version** — unofficial-builds signs nothing, so the sha256
  the build checks comes from `node-musl-sha256.txt`, not from the host serving the tarball. A
  version with no line fails the build; `scripts/pin-node-musl-sha.sh <version>` adds it (it
  refuses unless the host's SHASUMS256.txt and the downloaded tarball agree).
- **Alpine: mimalloc-insecure preloaded container-wide** (`LD_PRELOAD`), as in the browser
  images — musl's malloc maps and unmaps every large buffer; Buffer.alloc churn 7747 → 2877 ms CPU
  (ubuntu 3234). Every process here inherits it.
- **That node, registered in the tool cache** — so `actions/setup-node` resolves it instead of
  downloading another one (see [Keeping `actions/setup-node`](#keeping-actionssetup-node)).

## What it implies
- Built for **both modes and both OSes**: `ubuntu-dood-node`, `alpine-dind-node`, etc.
- The installed Node **minor floats** on Ubuntu (NodeSource serves the latest in that line); Alpine
  installs exactly `NODE_VERSION`. The version-pinned tag (`…-nodeXX.YY`) reflects what's actually
  installed.
- **`node-perf-gate`** (in `test-and-publish.yml`) times `bench/node-perf-kernel.cjs` on the alpine
  node against the ubuntu node, `node:<version>-bookworm-slim` and the alpine node it replaces, on
  one runner. Report-only until its margins are sized.
- **No node-gyp toolchain here** — inherits the [`gha-tools` compiler omission](../ubuntu-gha-tools/README.md#whats-deliberately-omitted-and-why).
  For `npm`/`pnpm install` runs that compile native modules, use the
  [`-gyp` variant](../pnpm-gyp/README.md) (`{os}-{mode}-pnpm-gyp`).
