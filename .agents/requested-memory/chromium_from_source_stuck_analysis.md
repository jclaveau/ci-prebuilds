---
name: chromium-from-source-stuck-analysis
description: What we know so far about the chromium-from-source build wall + proposed multi-job workflow refactor
metadata:
  type: project
---

## Where we are

- **Goal**: build chromium-from-source on Alpine/musl to verify the UA-stylesheet apk bug, then file the Alpine bug from CI.
- **Wall**: every iter caps at 6h (GHA hosted-runner hard limit). Build needs ~13h cold.

## What DOESN'T work

1. **Split-build via resumable Docker layer RUNs** (v10-v14, [[project_chromium_from_source_split_build]])
   Approach: 3 RUNs each `timeout 18000 ninja || true`, cache-to=registry keeps partial obj/.
   Fails because: [[project_buildkit_cacheto_commit_semantics]] — BuildKit's cache-to only pushes when `docker buildx build` exits normally. Cap-cancelled build → NO cache pushed. Every iter starts cold.

2. **GN feature-cut flags** (v16, commit 049b3aa)
   Added `enable_webrtc=false`, `use_dawn=false`, `skia_use_dawn=false`, `skia_use_vulkan=false`, `angle_enable_vulkan=false`.
   Result: v15 total compiles 37042 → v16 total compiles 36923 (delta 119). Effectively zero shrink. WebRTC/Dawn compiles still fire. GN silently rejects unknown flags.

3. **Same-commit re-dispatch as warm iter**
   Doesn't work because cache-to never pushed.

## What MIGHT work (multi-JOB refactor, NOT ATTEMPTED)

Split the single `build-chromium-headless-shell-from-source` job into N sequential jobs, each pushing an intermediate tagged image:

```
Job 1 (setup, ~30min): apt install + fetch source + gn gen
  push `chs-build-base-${sha}`
Job 2 (round 1, ~5h30min): FROM chs-build-base-${sha}
  RUN timeout 18000 ninja || true; commit layer
  push `chs-build-r1-${sha}`
Job 3 (round 2, ~5h30min): FROM chs-build-r1-${sha}
  RUN timeout 18000 ninja || true; commit layer
  push `chs-build-r2-${sha}`
Job N: FROM chs-build-r(N-1)-${sha}
  RUN ninja headless_shell; final artifact
```

Each `docker build` exits normally at end of its RUN → image pushes → next job pulls from tag. Docker layer holds obj/ state.

**Requires:**
- Dockerfile-per-job or single Dockerfile with `ARG BASE_IMAGE` parameter
- Workflow chain: `needs: [prior-round]` sequencing
- Cleanup: after final artifact tag exists, prune intermediate tags via GHCR API

Complexity: medium. Blast radius: chromium-from-source path only, no impact on FF/WK/prebuilt-chromium.

## Left dangling

- v16 cancelled at 4h — did NOT push cache (same as always)
- Task #13 (file Alpine apk bug) still blocked on from-source verification
- Task #17 (conformance toBeInViewport regression) still pending

## Related memories

- [[project_chromium_from_source_split_build]] — original split approach (now superseded)
- [[project_buildkit_cacheto_commit_semantics]] — why split-build fails
- [[project_gha_concurrency_group_serializes_dispatches]] — solved separately
