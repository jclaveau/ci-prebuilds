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

**"Warm rebuild" is still ~2-4h, NOT 30-40min.** Even with obj/ registry cache hot, a dispatch runs setup→r1..r8→finalize SEQUENTIALLY as separate jobs, each paying runner spin-up + multi-GB cache-image pull + ninja delta. I twice mis-quoted "30-40min" (2026-07-29) — the actual re-run to reach finalize is multiple hours. Live ninja progress isn't visible mid-job (job-logs API returns empty until completion; [[reference_gh_run_tests_log_via_zip]]). The finalize is the LAST stage, so any finalize-only change (e.g. strip) only pays off after all rounds replay.

**Binary is NOT stripped by default.** GN `symbol_level = 0` drops DWARF debug info but the linker still emits `.symtab`/`.strtab`; PW's official prebuilt ships stripped. A `strip --strip-all` pass in `stage-cache-layout.sh` (finalize stage) removes them (`.dynsym` kept, loading unaffected). Bigger lever = `is_official_build=true` (PGO/LTO) but that risks the 6h cap → deliberately not taken. NOTE the finalize-overlay dependency: editing stage-cache-layout.sh requires a fresh COPY in Dockerfile.finalize or the edit is inert on incremental dispatch ([[project_finalize_overlay_baked_scripts]]).

Related: [[project_pw_conformance_visibility_cluster]] runs against the eventually-built from-source binary to verify whether `--no-startup-window` / UA-stylesheet bug exists in the apk only.

**Per-round yield DECAYS sharply, and ninja's total shrinks as it goes.** Read the
counter from each round's log (`grep -oE '\[[0-9]+/[0-9]+\]' | tail -1`) — the
denominator is targets REMAINING at that round's start, not the whole graph:

```
r1  13976 of 37258  → 23282 left
r2   9148 of 23501  → 14353 left
r3   2926 of 14590  → 11664 left      (~5h11m per round, metronomic)
```

Cheap translation units go first; the expensive ones and the link steps remain, so
throughput fell 13976 → 9148 → 2926 at constant wall-clock. **Estimate completion
from the counter, never from "round N of 8"** — at r3's rate the 11664 remaining
needed ~4 more rounds, but a continued decay would exceed the r1..r8 budget
entirely and finalize would run against an incomplete tree. Watch the yield of each
round as it lands; that is the early warning.
