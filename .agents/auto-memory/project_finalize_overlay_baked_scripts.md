---
name: project_finalize_overlay_baked_scripts
description: Scripts under chromium-headless-shell/scripts are baked into the setup image; the split-build Dockerfile.finalize only re-COPYs SOME of them fresh, so an edit to a baked-but-not-overlaid script is INERT on an incremental (cache-warm) dispatch.
metadata:
  type: project
---

`Dockerfile.setup` bakes the whole scripts dir (`COPY chromium-headless-shell/scripts /work/.../scripts`) into the setup image, which becomes the BASE_IMAGE chain for every round + finalize. So on an **incremental** from-source dispatch (rounds resume from registry cache), the finalize container runs the **setup-baked** copy of each script — NOT your branch edit — unless finalize re-COPYs it fresh.

`Dockerfile.finalize` historically overlaid ONLY `ninja-resume.sh` (with an explicit comment on exactly this rationale). Any OTHER script it `RUN`s (e.g. `stage-cache-layout.sh`) needs the same fresh `COPY` or its edit silently doesn't run.

**Why:** 2026-07-29 I added a `strip --strip-all` pass to `stage-cache-layout.sh` (PR #87) to shrink from-source chromium. It would have been a **no-op on the incremental dispatch** — the finalize RUN reuses the baked pre-strip script. Caught it before dispatching; PR #88 added `COPY .../stage-cache-layout.sh` to finalize. Same class as [[project_multijob_base_image_audit]] (stale BASE_IMAGE) — a "fix" that looks landed but is inert because the split-build reuses a baked artifact.

**How to apply:** editing ANY `chromium-headless-shell/scripts/*.sh` that runs in `Dockerfile.finalize` (or a round Dockerfile) → confirm that Dockerfile re-COPYs it fresh, else the edit only lands on a COLD full rebuild. The single-shot `Dockerfile` (line ~66 COPYs scripts + runs them fresh) is unaffected; the trap is the multi-job split path (setup→r1..r8→finalize). Grep the finalize Dockerfile for a matching `COPY` before trusting a script edit shipped. [[project_chromium_from_source_split_build]] [[feedback_verify_impact_of_every_change]]
