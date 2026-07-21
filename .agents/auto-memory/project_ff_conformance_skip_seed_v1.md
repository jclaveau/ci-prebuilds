---
name: ff-conformance-skip-seed-v1
description: First FF conformance skip-list seed (2026-07-08, run 28952021038). Whole-file skips clustered around `browserContext._enableRecorder()` returning empty error on musl (Juggler recorder-binding gap); title skips clustered around cross-process iframes, file:// subframes, locale, detached-frame handling.
metadata:
  type: project
---

Seeded from FF conformance run 28952021038 — first real signal after
the `--remote-debugging-port=0` workaround landed
([[pw-upstream-juggler-handshake-hang]]).

**Cluster patterns to look for on new fails:**

- **`browserContext._enableRecorder` (empty error)** — whole-file skip.
  Affects `tests/library/inspector/cli-codegen-*.spec.ts`,
  `selector-generator.spec.ts`, `trace-viewer*.spec.ts`,
  `debug-controller.spec.ts`, `slowmo.spec.ts`. Juggler binding for
  PW's recorder API doesn't exist in our musl build. Root cause is
  Juggler-side, not just skip candidate — a real fix would restore
  the recorder API in `juggler/protocol/*`.
- **Proxy stack** — whole-file skip: `proxy`, `browsercontext-proxy`,
  `browsercontext-cookies-third-party`, `browsercontext-reuse`. Our
  musl build doesn't wire the full proxy stack PW expects.
- **client-certificates** — whole-file skip. NSS OCSP.
- **Cross-process iframe / docShell access** — title skip. Juggler
  cross-origin access gap on our build. Error: `Permission denied to
  access property "docShell" on cross-origin object`.
- **file:// subframes / bfcache** — title skip. musl file:// resolver
  quirk in FF.
- **Locale** — title skip. Alpine ICU package differs from Ubuntu.
- **Detached frame handling** — title skip. Juggler frame lifecycle.
- **CORS / CSP throw-message variance** — title skip. Error-string
  wording differs on musl.

**PW upstream-known fails (shared with Ubuntu-FF baseline)** —
3 fails: `should support webgl @smoke`, `should support webgl 2
@smoke`, `page screenshot › should work for webgl`. Included in
BOTH `skip-list/firefox.titles.txt` AND
`skip-list-ubuntu/firefox.titles.txt`.

**Baseline stats:** 8/10 Alpine shards ≈ 92% pass, 277 total fails.
After seed: 2/10 shards green on next run (still iterating).

**How to apply:** When seeding a new browser's skip-list, extract
failures across shards, cross-reference with Ubuntu baseline, cluster
by common error signature (`grep -oE "\[2K  [0-9]+\) \[browser-...`).
Whole-file for structural gaps (missing API); titles for scattered
per-test divergences. Track structural clusters as separate follow-up
issues, not indefinite skips.

**Sequel work:** Fix `browserContext._enableRecorder` in juggler
protocol; fix cross-origin docShell access in juggler content agent;
add ICU-locale package to runtime image for locale tests.

Related:
- [[pw-upstream-juggler-handshake-hang]] — the unblock that produced
  this signal
- [[pw-conformance-visibility-cluster]] — chromium-side skip-list
  precedent
