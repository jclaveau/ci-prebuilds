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

**Mirror-image bug, PR #200: an ignored path is not the only way to waste a
publish — a NON-ignored one can cancel a real one.** Before #200,
`.agents/**` was not in `paths-ignore` at all, so three memory-only commits in
a row each triggered its own `test-and-publish` run. The workflow's
concurrency group is per-ref with `cancel-in-progress: true`
([[gha-concurrency-group-serializes-dispatches]]), so each new memory push
cancelled the PREVIOUS commit's still-running publish — two genuine publishes
(`34349445882`, `34349591921`) died `cancelled` mid-build for no reason
related to their own content. Fixed by adding `.agents/**` to `paths-ignore`
on both `push` and `pull_request` blocks: memory files are provably no image
input, so they should never occupy the ref's build slot. General rule: any
path that changes on every session but never changes what ships belongs in
`paths-ignore`, even if — especially if — nothing currently depends on that
exact path being watched.
