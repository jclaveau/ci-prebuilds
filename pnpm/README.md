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

## `pnpm install -g` under `act --bind --user <non-1001>`

Works, with `--group-add 1001` — the flag the
[act recipe](../dood/README.md#running-locally-with-act---bind) already carries.

`pnpm install -g` writes the global tree, the content-addressable store and the config as
whoever runs the job, but the image bakes those dirs as `runner` (UID 1001) and the
consumer's host UID is unknown at build time. So the pnpm layer hands them to the `runner`
**group** instead — `2775`, setgid, same shape gha-tools already uses for
`/opt/hostedtoolcache`:

    $PNPM_HOME  $PNPM_HOME/bin  ~/.cache/pnpm  ~/.config/pnpm  ~/playwright-browsers

Directories only: chmod-ing the baked files would copy every one of them up into this
layer. They keep `0755 runner:runner`, but note what that does *not* buy — POSIX governs
unlink by the containing directory, so a job holding group `runner` can replace the baked
`playwright` shim, and `pnpm install -g playwright@<other>` legitimately does. A sticky
bit would forbid that, and would break that upgrade with it, so the dirs stay `2775`.
The trade, stated plainly: anything holding group `runner` may create, replace and delete
entries in those dirs. Inside these images only `runner` holds it, and under act the
consumer opts in explicitly with `--group-add 1001`.

Ancestors of those dirs (`~/.local`, `~/.local/share`, `~/.config`) are chowned to
`runner` but left `0755` — they only need to be traversable.

`npm install -g` is unaffected and still needs `sudo`: its prefix is the root-owned
`/usr/lib/node_modules`, which this change does not touch. Use `pnpm install -g`, or the
`-sudoer` image flavour.

Asserted by `tests/act/smoke-dood-bind-arbitrary-uid.yml` (UID 5000), which drives a real
`pnpm install -g` beside the pre-baked playwright rather than only probing `mkdir`.

### Why this is not pnpm#3699

The earlier diagnosis here blamed
[pnpm/pnpm#3699](https://github.com/pnpm/pnpm/issues/3699) — `linkBin` re-`chmod`ing bin
entries it does not own. That was a pnpm ≤11 shape, where every global install shared one
`node_modules`. pnpm 12 gives each `install -g` its own `global/v11/<hash>` tree, so it
never walks a tree another user baked, and the wall we actually hit was plain directory
ownership (`ERR_PNPM_PNPM_DIR_NOT_WRITABLE`). #3699 itself was fixed upstream on
2026-09-22 by [pnpm#15281](https://github.com/pnpm/pnpm/pull/15281) — already-executable
targets skip the `chmod` — which landed after `v12.6.0` was cut and so ships in the next
release; nothing here waits on it.
