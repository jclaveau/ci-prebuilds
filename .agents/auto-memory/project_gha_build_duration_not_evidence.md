---
name: project_gha_build_duration_not_evidence
description: a suspiciously fast (or slow) CI build duration is not evidence of what got rebuilt — check the artifact's own output (probe numbers, digest, label) instead
metadata:
  type: project
author: Jean Claveau
---

The TP consumer rebuild after retagging WebKit (PR #192,
[[project_wk_promote_gate_holds_the_nightly_bench]]) finished in **21
seconds**. That reads like "nothing was rebuilt, the retag didn't take" — the
kind of duration signal that has burned this repo before (a suspiciously fast
build usually means a cache hit masking a no-op).

**Why it was actually fine here.** Only the `wk-2336` producer tag moved; the
Dockerfile step that resolves it is a `COPY --from=` against an image
reference, so BuildKit re-resolved the tag to its new digest and only the
genuinely-unchanged consumer layers (fastfmod, zlib-ng compile steps, etc.)
were reused from cache. A 21-second build after a producer retag is the
*correct* outcome, not a red flag — the expensive work (compiling WebKit) had
already happened on the producer side.

**How to apply.** Duration alone decides nothing in either direction — it
can't distinguish "cache hit on unchanged inputs" from "didn't pick up the
change I made." Verify with something that actually reflects content: the
image's own inline probe/test output, the published `org.opencontainers.image.revision`
label, or a digest diff against the pre-build state. Confirmed here by reading
the rebuild's own perf probe (`launch 0.87`, matching the retagged WebKit's
known number) rather than trusting the 21s figure either way.
