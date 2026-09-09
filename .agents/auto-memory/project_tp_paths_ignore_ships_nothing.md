---
name: project_tp_paths_ignore_ships_nothing
description: test-and-publish.yml's paths-ignore blanket-excludes playwright/alpine-browsers/**, but the consumer image compiles fastfmod/** and strip-bundled-libs.sh from under that exact path, so a fix there merges green and republishes nothing
metadata:
  type: project
---

2026-09-08, PR #167 (the fastfmod chunked-divide rewrite,
[[project_wk_fastfmod_ships]]) merged green and republished `latest` with
**nothing changed** — no error, no red bar, just a silent no-op. Cause:
`.github/workflows/test-and-publish.yml` has
`paths-ignore: playwright/alpine-browsers/**`, meant to skip republishing
`latest` on browser-producer-only changes, but the **consumer** image
(`playwright/Dockerfile.alpine`) compiles two things that live exactly under
that ignored path: `fastfmod/**` and `strip-bundled-libs.sh`. A source-only
edit to either is invisible to the trigger even though it changes what
`latest` ships. #167's fix only reached `latest` earlier by the accident of
an unrelated commit landing in the same push.

Fixed in #168: carved `fastfmod/**` and `strip-bundled-libs.sh` back out of
the `paths-ignore` list. Before touching that ignore list again, check
`Dockerfile.alpine` for what the consumer actually `COPY`s or compiles from
inside an otherwise-ignored producer directory — this is the same shape of
bug as [[project_finalize_overlay_baked_scripts]] (an edit under a path that
*looks* owned by one image but is silently consumed by another).

**Related gotcha caught during the same fix:** a `workflow_dispatch` of
`test-and-publish.yml` is push-gated for the actual publish step — it builds
but never publishes `latest`, no matter how green. To measure a dispatched
build, probe the GHCR **sha-tagged** image the run itself produced instead of
waiting for (or expecting) a publish that will not happen.
