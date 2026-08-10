---
name: webkit-strip-gtk-gate-promote
description: 2026-08-01 — WebKit artifact now strips ELF symbols in build-webkit-finalize (WPE-only, wpe strip ~2.5GB→1.9GB) and GTK port is gated OFF by default (build_webkit_gtk input, GTK_STAGE=none). The GTK skip cascade-skipped smoke/promote (fixed with `!cancelled()` prefix, commit 1752fc1). Promote tags = wk-REV / wk-VER / wk-latest on GHCR + Docker Hub, pushed via local `imagetools create` (needs write:packages scope).
metadata:
  type: project
---

**2026-08-01: strip + GTK gating shipped, promote unblocked.**

- **Strip:** `Dockerfile.finalize` added a `wpe` stage that runs
  `find ... -exec strip --strip-all {} +` on `minibrowser-wpe-dist` before
  the artifact stage (`COPY --from=wpe /work/minibrowser-wpe-dist`).
  Commented-out GTK mirror stage stays for when GTK re-enables. Log line to
  look for: `wpe strip: <before> -> <after>`.
- **GTK gate:** new `build_webkit_gtk` workflow_dispatch input (default
  false); GTK build jobs `if:` on it, `GTK_STAGE=none` on shared prep.
  conformance-webkit stays dispatch-gated (`run_webkit_conformance`).
- **Regression caught:** skipped GTK jobs cascade-skipped `smoke-webkit` +
  `promote-webkit` (bare `if:` on `needs` output doesn't break the
  transitive skip — actions/runner#491). Fixed in 1752fc1: both `if:` now
  prefixed `!cancelled() &&`. **Not yet validated in CI** — next webkit
  build (dispatch `build_webkit=true`) must show smoke-webkit + promote-webkit
  actually running.
- **Promote:** `promote-webkit` tags `wk-${REV}`, `wk-${VER}`, `wk-latest`
  (plus Docker Hub mirrors) from the build's `wk-sha-<sha>` tag. For the
  deferred/broken case, promote locally with:
  `docker buildx imagetools create -t ...:wk-<REV> -t ...:wk-<VER> -t ...:wk-latest <src:wk-sha-...>`.
  REV/VER come from source-prep outputs (PW → browsers.json webkit
  `.revision` / `.browserVersion`). 2026-08-01: PW 1.60.0 → REV=2287 VER=26.4.
- **Local GHCR push blocked until the gh token has `write:packages`**
  (gh auth refresh, interactive — see `reference_ghcr_write_packages_scope`).
  2026-08-01 promote done manually: wk-2287 / wk-26.4 / wk-latest all now
  point to digest 0ec9157ad (stripped WPE-only).
- **Docker Hub gap filled manually too** (2026-08-01): the stored
  `~/.docker/config.json` credential for `jclaveau` (index.docker.io) has Hub
  push rights — no GH secret needed. NOTE: cross-registry `imagetools
  create` COPIES the blobs (Hub had never seen the stripped layers, ~1.9GB,
  several minutes) and runs one copy PER tag in parallel — use `--tty=false`
  / detached + DONE-marker polling, don't expect a fast manifest PUT.
  Result: hub wk-2287 / wk-26.4 / wk-latest → 0ec9157ad.
