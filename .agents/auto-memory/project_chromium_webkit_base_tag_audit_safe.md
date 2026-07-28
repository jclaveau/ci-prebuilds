---
name: project_chromium_webkit_base_tag_audit_safe
description: Audit result — the FF prebuilt-base pin-only-tag staleness bug does NOT replicate in chromium (apk/from-source/headed) or webkit. They're structurally immune (all intermediate images sha-scoped, no iter/prebuilt-base manifest-inspect auto-select). FF was the sole instance.
metadata:
  type: project
---

Audited 2026-07-28 (answers PR #81 open Q2). The
[[project_ff_prebuilt_base_pin_only_tag_staleness]] bug class exists in exactly
ONE place: the firefox iter path's `docker manifest inspect "$BASE_TAG"`
auto-select (`playwright-alpine-browsers.yml:329`) — now content-addressed on
the patch-set hash. Chromium + webkit have NO analog.

**Why they're immune:** neither added an iter/prebuilt-base fast-path. All heavy
work is split into `*-sha-${{ github.sha }}` rounds, unconditionally rebuilt per
dispatch (job `if:` gates are event/label-based, never existence-based). A
source-only patch = new commit = new sha = fresh tag namespace, zero reuse path.
Cost: they always pay the full rebuild — exactly what FF's iter path optimized
away and got bitten by.
- (a) chromium apk: build `chs-sha-${sha}`; promote `chs-${rev}` via imagetools
  FROM the fresh-sha image — no skip-if-exists gate.
- (b) chromium-from-source r1..r8, (c) headed r1..r14: `chs-build-rN-sha-${sha}`
  / `chr-build-rN-sha-${sha}`, `BASE_IMAGE` = prev round's sha tag; no round
  cache; `Dockerfile.setup` COPYs versions.env+args.gn overlays+scripts before
  the apply-and-build RUN.
- (d) webkit: `wk-src-sha-${sha}` + `wk-{wpe,gtk}-N-sha-${sha}`, BASE_IMAGE via
  sha-scoped `outputs.tag`. One moving cache `buildcache-wk-src` is a normal
  BuildKit layer cache — `Dockerfile.source-prep` COPYs every repo-owned input
  before its RUN, so a source patch invalidates. (`apply-and-build-port.sh`,
  `bundle-dist.sh`, `cmake-flags.overlay` are deliberately NOT in source-prep —
  source-prep doesn't consume them; `Dockerfile.port` re-COPYs them, no cache,
  sha-scoped BASE — so the `_FORTIFY_SOURCE` Skia fix etc. always applies.)

Consumer-side `docker manifest inspect` calls (`on-demand-build.yml:193`,
`smoke-webkit-iter.yml:62`, `benchmark-playwright.yml:374`) are assertions /
byte-size reads, NOT reuse-skips — not the bug class.
