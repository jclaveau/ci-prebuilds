# pnpm layer — `{ubuntu,alpine}-{dood,dind}-pnpm`

Adds [pnpm](https://pnpm.io) on top of the [node](../node/README.md) layer.

## Usage

Published as `jclaveau/<os>-<mode>-pnpm` on Docker Hub — four variants
(`ubuntu-dood-pnpm`, `ubuntu-dind-pnpm`, `alpine-dood-pnpm`, `alpine-dind-pnpm`).
Tags: `:latest` and version-pinned `:<os>-<node-minor>-<pnpm-minor>`, e.g.
`jclaveau/ubuntu-dood-pnpm:ubuntu24.04-node22.12-pnpm9.15`. Append `-sudoer` to the image name for
the non-hardened flavor.

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

If `pnpm install` ever rebuilds a `*.node` (native addon), switch to
[`-pnpm-gyp`](../pnpm-gyp/README.md).

## What it adds
- **pnpm** (pinned by the `PNPM_VERSION` build-arg), with `PNPM_HOME` on `PATH`.

## What it implies
- Built for **both modes and both OSes**: `ubuntu-dood-pnpm`, `alpine-dind-pnpm`, etc. — the same
  Dockerfile serves both (get.pnpm.io ships a musl-static binary that runs on Alpine).
- Inherits Node from the node layer; **slim — no compiler**. For native-addon builds use the sibling
  [`-gyp` variant](../pnpm-gyp/README.md) (`{os}-{mode}-pnpm-gyp`), which is this layer + the node-gyp
  toolchain.
- The version-pinned tag carries the pnpm minor (`…-pnpmX.Y`); the `-gyp` variant adds a `-gyp` suffix
  (`…-pnpmX.Y-gyp`).

## Known limit: `pnpm install -g` under `act --bind --user <non-1001>`

When a consumer runs the [`act --bind --user $(id -u):$(id -g) --group-add 1001`](../dood/README.md#running-locally-with-act---bind)
recipe on a pnpm-bearing image and does `pnpm install -g <pkg>` during the job, pnpm's
`linkBin` step re-`chmod`s the bin entries of every package in the global tree — including
pre-baked CLIs on the `*-playwright[-gyp]` layers. POSIX `chmod(2)` is owner-or-root
regardless of mode bits or ACLs, so the host UID EPERMs on inodes owned by the image-build
`runner` user.

No image-side fix without giving up isolation. Tracked upstream:
[pnpm/pnpm#3699 — EPERM: operation not permitted, chmod](https://github.com/pnpm/pnpm/issues/3699)
(open since 2021, maintainer-acknowledged, no fix in 4 years). Workaround in the consumer
workflow until then, gated so it's a no-op on hosted GHA (where `USER=runner` *is* the owner):

```yaml
- name: Adopt /home/runner ownership (act-local only)
  if: ${{ env.ACT == 'true' }}
  run: sudo chown -R $(id -u):$(id -g) /home/runner/.local /home/runner/.cache
```

Requires the `-sudoer` flavor under act — the published `:latest` is hardened and strips
broad `sudo`, so the `chown` step would fail. Append `-sudoer` to the image tag for the
local dev loop.
