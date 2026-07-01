---
name: chromium-from-source-split-build
description: GHA 6h hosted-runner cap kills chromium-148 cold build (~13h on 4-vCPU); resumable Docker-layer ninja split persists partial obj/ across CI iters via cache-to=registry
metadata:
  type: project
---

GHA hosted-runner job time has a hard 6h cap. `timeout-minutes: 600` is silently clamped by infrastructure — confirmed by v9 (28331430464) cancelling `build-chromium-headless-shell-from-source` at exactly 6h elapsed with obj/ at ~38% .o coverage.

**Why:** chromium 148 cold-build is ~13h on a 4-vCPU hosted runner. sccache GHA-backend pre-warms cold to ~3-4h once a green baseline exists, but the FIRST cold build can never complete in 6h.

**How to apply:** split ninja into N resumable Docker layers. obj/ lives in image filesystem (NOT a `--mount=type=cache`) so each round's partial .o files commit as a layer; `cache-to=type=registry,mode=max,ref=…` pushes layers; next iter cache-from restores them and ninja resumes from existing obj/ state.

Pattern (`playwright/alpine-browsers/chromium-headless-shell/`):
- `apply-and-build.sh` — `PW_CHROMIUM_SKIP_NINJA=1` early-exit after gn gen
- `scripts/ninja-resume.sh` — `timeout 18000 ninja || true` for non-final rounds (5h cap, exit 0 on SIGTERM so layer commits); `ninja` (no timeout) for final round (fails layer if incomplete)
- `Dockerfile` — 3 RUNs each invoking `ninja-resume.sh /work <round-name> [final]` with sccache + GHA-cache secrets mounts

NOT a chunk-by-target approach (e.g. ninja's `-t deps` partitioning) — that requires deeper chromium internals knowledge and offers no benefit over raw timeout-and-retry since ninja is already incremental.

Self-hosted runner approach explicitly REJECTED by user (2026-06-28). Stay on GHA hosted, take however many iters cold-warm takes.

Related: [[project_pw_conformance_visibility_cluster]] runs against the eventually-built from-source binary to verify whether `--no-startup-window` / UA-stylesheet bug exists in the apk only.
