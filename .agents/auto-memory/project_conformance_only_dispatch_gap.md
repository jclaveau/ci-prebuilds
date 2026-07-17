---
name: conformance-only-dispatch-gap
description: A skip-list-only conformance probe still forces a full browser rebuild because conformance image_ref is pinned to same-run github.sha; add a conformance-only path against stable -edge tags
metadata:
  type: project
---

Skip-list edits are read at RUNTIME by the conformance runner (build-runner.sh
COPY-froms the browser image; run.sh loads the skip-list from the checkout).
So a skip-list change needs NO browser rebuild. But the conformance jobs in
`playwright-alpine-browsers.yml` pin `image_ref: <tag>-sha-${{ github.sha }}`,
which only exists if THIS run builds it. So dispatching with `build_*=true`
(the only way to reach the conformance jobs) triggers the browser build jobs.

**The trap:** those compile rounds use sccache (ghac backend BROKEN, 0 hits —
see [[sccache-ghac-readonly-v18]]) + BuildKit obj/ registry cache. The obj cache
7-day-evicts, so a probe run ~7 days after the last build recompiles cold —
chromium-fs ~hours across its 8 rounds, WK ~hours across wpe/gtk rounds. Iter
29565116253 (2026-07-17 bucket-C probe) hit this: r1 alone ran 49min. ~8h of
CI to validate 6 skip-list line changes.

**How to apply:** for a skip-list-only probe, DON'T rebuild the browser. Options:
(1) add a `conformance_only` dispatch input that points the conformance jobs'
`image_ref` at a stable published tag (`chs-fs-edge` / `wk-edge` / `ff-latest`)
and drops the `needs: [build-*]` gate; (2) or run the reusable `pw-conformance.
yml` against a stable tag via a thin dispatch wrapper. Either cuts a probe from
~8h to ~40min (conformance shards only). Only rebuild when the browser SOURCE
changed. Relates to [[iterate-deps-locally-before-ci-rebuild]] (same "don't
rebuild to test a consumer-side change" principle).
