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
(`$RUNNER_TOOL_CACHE/node/<version>/<arch>`, symlinks into `/usr/bin` — no second node in the
image), which is the only place `actions/setup-node` looks before it downloads one. Two things a
workflow must do for that lookup to hit:

```yaml
    container: jclaveau/alpine-dood-node:latest
    env:
      # a container job's default /__t is the HOST runner's glibc tool cache, not the image's
      RUNNER_TOOL_CACHE: /opt/hostedtoolcache
    steps:
      - uses: actions/setup-node@v4
        with:
          node-version: 24.x   # a range: the installed minor floats, so an exact version misses
```

Miss the lookup and `setup-node` installs the `actions/node-versions` build, which is glibc-only:
on Ubuntu a redundant ~56 MiB download per job, on Alpine a node that cannot run — and the step
itself still exits 0, so the failure surfaces one step later as
`cannot execute: required file not found`.

`register-node-in-tool-cache` stays on the image, so a job that upgrades node in place can
re-register it.

## What it adds
- **Node.js + npm** — on Ubuntu from NodeSource (the major comes from the `NODE_VERSION` build-arg); on
  Alpine from `apk` (`nodejs npm`, the version Alpine ships for that release).
- **That node, registered in the tool cache** — so `actions/setup-node` resolves it instead of
  downloading another one (see [Keeping `actions/setup-node`](#keeping-actionssetup-node)).

## What it implies
- Built for **both modes and both OSes**: `ubuntu-dood-node`, `alpine-dind-node`, etc.
- The installed Node **minor floats** (NodeSource/apk serve the latest in that line); the version-pinned
  tag (`…-nodeXX.YY`) reflects what's actually installed.
- **No node-gyp toolchain here** — inherits the [`gha-tools` compiler omission](../ubuntu-gha-tools/README.md#whats-deliberately-omitted-and-why).
  For `npm`/`pnpm install` runs that compile native modules, use the
  [`-gyp` variant](../pnpm-gyp/README.md) (`{os}-{mode}-pnpm-gyp`).
