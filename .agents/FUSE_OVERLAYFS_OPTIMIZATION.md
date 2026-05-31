# DONE (2026-05-28): fuse-overlayfs is the dind storage driver (faster than vfs)

> **Status: resolved & green.** Confirmed in CI on commit `6126aff` — all dind jobs
> (`test-base`/`test-pnpm`/`test-playwright`) pass with `DOCKER_STORAGE_DRIVER=fuse-overlayfs`.
> So rootful nested `dockerd --storage-driver=fuse-overlayfs` works on GitHub-hosted runners
> (`/dev/fuse` present, confirmed via `tmp-dind-debug.yml`). Shipped: `fuse-overlayfs` installed in
> `dind/Dockerfile`; `test-base` env set to `fuse-overlayfs`; `vfs` remains the documented fallback.

## Background

The `-dind` images let `dockerd` auto-detect the storage driver, and the CI `test-base`
job forced `DOCKER_STORAGE_DRIVER=vfs` because **overlay2-on-overlayfs is unstable in GHA container
jobs** (the inner daemon passes its readiness check, then crashes). `vfs` always works but is slow
(no copy-on-write; deep-copies every layer) and disk-heavy.

## The optimization

`fuse-overlayfs` gives real overlay/CoW semantics in userspace — close to native `overlay2`, far
faster/leaner than `vfs`, and works nested where kernel overlay2 fails. It's what the official
`docker:dind` image falls back to.

## What it needs

1. **Install the package** in the `-dind` overlay (or base): `apt-get install -y fuse-overlayfs`.
2. **`/dev/fuse` at runtime.** Our dind jobs already run `--privileged` (exposes host devices), and
   GitHub-hosted `ubuntu-latest` ships FUSE — but this is the one thing that varies by runner
   (self-hosted especially) and was never verified in *our* GHA container job. vfs needs none of this.

## Plan when picked up

- Add `fuse-overlayfs` to `dind/Dockerfile` (apt install).
- Set `DOCKER_STORAGE_DRIVER=fuse-overlayfs` for the dind tests (replacing the `vfs` env in
  `test-base`), keeping `vfs` documented as the guaranteed fallback.
- Let one CI run confirm `/dev/fuse` is usable; if not, revert to `vfs`.

Parked 2026-05-28 at the user's request ("keep for later") after switching the dind tests to `vfs`.
