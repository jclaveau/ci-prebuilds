---
name: similar-projects-landscape
description: Adjacent/competitor projects to github-action-container-images (prebuilt GHA container images). No popular repo does the exact dood+dind layered matrix as a drop-in CI optimization.
metadata:
  type: reference
---

Web-search landscape (2026-05-29) for repos achieving the same goal as this project —
prebuilt GHA container-job images that speed up CI and mimic `ubuntu-latest` (incl. `docker compose`).

**Key finding:** no popular repo does this project's exact combination — a thin **dood + dind**
matrix, layered base → pnpm → playwright, meant as a drop-in optimization that preserves the
normal container-job shape. The niche looks genuinely underserved; existing projects each cover
only one slice.

- **`catthehacker/docker_images`** (ghcr.io/catthehacker/ubuntu) — closest in spirit: prebuilt
  copies of GHA hosted-runner images for `act`, with `act-*`/`full-*`/JS variants (node v20/v24,
  pnpm, yarn, nvm). But: `act`-parity focused, monolithic, very large (20GB+), no dood/dind split,
  no slim-overlay layering.
- **`actions/runner-images`** — upstream definitions of `ubuntu-latest` (the env we mirror). Ships
  VM image build scripts, not pullable container images.
- **`mcr.microsoft.com/playwright`** — official Playwright image; overlaps only the playwright layer
  (browsers+deps). No docker/compose, no pnpm tooling, no dind.
- **`ghcr.io/pnpm/pnpm`** — official pnpm base image; overlaps only the pnpm layer. No docker.
- **`docker:dind`** — canonical true-DinD image (our fuse-overlayfs fallback reference). Pure
  docker, no node.
- **actions-runner-controller (ARC)** `containerMode: dind` — same *problem*, k8s deployment model.
  Their issues (#2967, #3281) and `docker/for-linux#1416` document the exact "bind mounts created
  in the job container don't resolve in docker-launched containers" failure that motivated our
  separate-socket dind design ([[feedback_autonomous_ci_loop]] is the same repo's CI work).
- **`devcontainers/images`** — prebuilt dev-container images with a docker-in-docker *feature*;
  dev-container-oriented, not CI-job-shaped.

**How to apply:** when justifying this project's existence or comparing approaches, cite that the
pieces exist scattered (Playwright/pnpm/docker:dind official images, catthehacker for act, ARC for
the k8s dind case) but nobody assembles the dood+dind opt-in layered matrix the way this repo does.
