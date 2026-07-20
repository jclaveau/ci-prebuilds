---
name: project_chromium_capture_navigation_compositor_fix
description: chromium capture-navigation black-frame on CI software-GL — fixed via two compositor launch flags; the exact --shard=N/20 repro was the diagnostic key
metadata:
  type: project
---

`tests/library/video.spec.ts` `screencast › should capture navigation` (records a
cross-process black→gray nav, asserts LAST frame `isAlmostGray`) DETERMINISTICALLY
red on CI shard 17 (runs 29665829491, 29748697128) — captured black `(0,0,0,255)`.
FIXED 2026-07-20 (run 29754333185 all-20-shards green, un-skipped).

**Root cause:** accumulated software-GL (SwiftShader) compositor state late in a big
shard (test ran at position 112/113) holds the OLD black content past
`context.close()` → black last frame. Not an Alpine browser bug — any chromium on
contended software-GL.

**Fix:** inject BOTH chromium launch args in `conformance/run.sh` config sed —
`--run-all-compositor-stages-before-draw` + `--disable-new-content-rendering-timeout`.
NEITHER ALONE passes (validated: each alone → 1 failed; both → 113/113). run-all forces
synchronous compositing of the new gray; disable-timeout stops the old-content hold.

**How to apply / the diagnostic key:** the crack was reproducing with the EXACT
`--shard=17/20` locally (SwiftShader forced via `--use-angle=swiftshader --use-gl=angle`
on jean's GPU box). Isolated 14/14 AND full `video.spec.ts` 28/28 BOTH passed — only
the exact 113-test shard composition at the late position reproduced. When a CI test is
green isolated + green whole-file but red on a numbered shard, run the EXACT `--shard=N/K`
before concluding flake or hardware-specific. [[project_pw_conformance_visibility_cluster]]
[[project_conformance_structural_was_stale]]
