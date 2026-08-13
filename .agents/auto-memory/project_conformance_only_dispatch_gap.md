---
name: conformance-only-dispatch-gap
description: RESOLVED — pw-conformance.yml takes a free-form image_ref on workflow_dispatch, so a skip-list probe (or an A/B winner) runs against any published tag with no rebuild; only the producer's OWN conformance jobs pin same-run github.sha
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

**RESOLVED — option (2) already exists.** `pw-conformance.yml` carries its own
`workflow_dispatch` block taking `browser` / `image_ref` (free-form string) /
`pw_version` / `artifact_rev` / `headed`. So:

```
gh workflow run pw-conformance.yml --ref <branch> \
  -f browser=chromium -f image_ref=ghcr.io/jclaveau/playwright-alpine-browsers:chs-fs-<rev> \
  -f pw_version=1.60.0 -f artifact_rev=<rev>
```

runs the shards alone (~40min) against any published tag — a skip-list probe, a
re-check of an old artifact, or a fresh A/B winner. The producer's own
conformance jobs still pin `<tag>-sha-${{ github.sha }}`, which is correct
there; the gap was only ever in how I reached them.

**How to apply:** only rebuild when the browser SOURCE changed. Reach for the
standalone dispatch for everything else. Relates to
[[iterate-deps-locally-before-ci-rebuild]] (same "don't rebuild to test a
consumer-side change" principle).

**Also:** a workflow's `workflow_dispatch` inputs are worth reading before
concluding a capability is missing — this one was reusable-called from the
producer, and I only ever saw it through that call site.
