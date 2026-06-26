---
name: pw-upstream-juggler-handshake-hang
description: PW's upstream `tests/library/` test runner hangs at Juggler handshake on our musl FF artifact — every test sits idle for exactly 3min (PW default testTimeout) then SIGKILLs. Smoke layer passes with the same binary, so the divergence is in PW's fixture layer (tests/library/playwright.config.ts), not the build. Tracked in #60; job kept in-tree as `if: false`.
metadata:
  type: project
---

The `test-firefox-library-upstream` job in
`.github/workflows/playwright-alpine-browsers.yml` is disabled (`if: false`)
pending investigation of issue #60.

**Symptom (run 27004002735):** PW's runner launches FF
(`-juggler-pipe -silent`), FF reports `*** You are running in headless
mode.`, then sits idle for **exactly 180 seconds** (`+3m` in pw:browser
debug timestamps), then PW SIGKILLs and starts the next test. No
`--reporter=dot` output ever emitted — tests stuck before first protocol
message. ~14 tests cycled in the 45min job-timeout window. Zero pass.

**Why we know the FF binary is fine:**

- `smoke-firefox` (basic launch + goto + screenshot) → 22s green
- `smoke-firefox-library` (8 Juggler RPCs: Browser.getInfo,
  Network.setCookies, Page.frameAttached, evaluate, dialogs, screenshot,
  response) → 22s green on the SAME binary, SAME PW version (1.60.0)
- So launch + Juggler protocol + all standard RPCs work via
  `firefox.launch()` from the published PW SDK.

**What differs in PW's test framework:**

The test invocation in
`playwright/alpine-browsers/firefox/library-upstream/run.sh`:
```sh
PWTEST_UNDER_TEST=1 npx playwright test \
  --config=tests/library/playwright.config.ts \
  --project=firefox-library \
  --reporter=dot --workers=1 \
  tests/library/{browsertype-basic,browser,browsercontext-basic,browsercontext-cookies}.spec.ts
```

Suspects (read these first when picking up #60):
- `tests/library/playwright.config.ts` — likely sets a `globalSetup`,
  custom `_browserType` fixture, or extends baseTest in a way the
  patched-musl build doesn't satisfy.
- `PWTEST_UNDER_TEST=1` — enables a fixture path that may expect specific
  pref/extension/channel setup.
- The base fixture's `browser` setup probably uses `_setupInProcess` or
  opens an extra channel (CDP-over-Juggler bridge?) that our build
  doesn't bind.

**How to re-enable:**

In `.github/workflows/playwright-alpine-browsers.yml`, find the
`test-firefox-library-upstream:` job. Drop `if: false` and restore the
gate (already inlined as a YAML comment):
```yaml
if: |
  (github.event_name == 'pull_request' && contains(github.event.pull_request.labels.*.name, 'test-firefox-upstream'))
  || (github.event_name == 'workflow_dispatch' && inputs.test_firefox_library_upstream == 'true')
```

**Confirmed catastrophic 2026-06-26 against full 10-shard conformance (run 28239393075):**

Dispatched `conformance-firefox` via `run_firefox_conformance=true`
input. FF artifact built green on the same SHA. All 10 conformance
shards exhibited identical pattern:

- launched ~20 FF processes with `-juggler-pipe` over 60min
- every test asserted `Test timeout of 30000ms exceeded.`
- 0 useful PW assertions emitted (no `--reporter=line` output)
- all 10 shards hit GHA `timeout-minutes: 60` ceiling → CANCELLED
- `conformance-firefox / summary` → failure

Juggler-hang dominates: ~20/233 tests *attempted* per shard, all
fail at 30s. Full PW upstream conformance against musl Firefox is
not viable until this is root-caused.

Workaround paths considered:
1. Per-test timeout 5s — same outcome, denser failures.
2. Patch tests/library/playwright.config.ts to skip the hanging
   fixture stage — unknown which stage hangs.
3. Replace upstream config with custom config that launches FF
   directly via PW SDK (smoke-firefox-library pattern) — bypasses
   the bug but is no longer "what PW runs for its build".

Decision: `conformance-firefox` stays dispatch-gated and produces
a catastrophic-timeout signal as the baseline metric. Any future
Juggler fix is then measurable against this run.

**How to apply:** Do NOT remove the job, run.sh, or related plumbing.
They're parked, not abandoned — per [[land-disabled-over-revert]]. Any
future "let's run PW upstream tests" work starts from this job, not
from scratch.

Related:
- [[firefox-alpine-wip-pipeline]] — broader FF-on-Alpine context
- [[pw-version-aware-chs-rev-chain]] — how PW_VERSION pins propagate;
  upstream tests must match PW_VERSION exactly (run.sh clones
  `microsoft/playwright@v${PW_VERSION}`).
