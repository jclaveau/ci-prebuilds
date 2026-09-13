---
name: project_conformance_parity_flaky_is_pass
description: the runtime parity gate summed `passed` only, so one flaky retry on Alpine read as a -1 regression (run 34652798588, shard 6 library `110 passed, 1 flaky` vs Ubuntu 111) — PR #224 writes `flaky=` in stats.txt and adds it to both sides' pass total
metadata:
  type: project
---

Playwright lists a test that failed and then went green on retry under
`flaky`, not `passed`, and exits 0 for it. `conformance/run.sh` parsed the
`N passed` line only, so `check-runtime-parity.sh` saw 5948 vs 5949 on a
build whose 20 shards were all green (clang23 candidate, 2026-09-13).

**Finding the test:** diff the per-shard `stats.txt` between sides (they
differed on exactly one line), then read that shard's `<suite>.log` tail —
PW prints the flaky test's title there
(`chromium.spec.ts:177 serviceWorker(), and fromServiceWorker() work`).

**Fix (#224):** `flaky=` beside the other counts; the gate adds it to
`passed` on BOTH sides, so a flaky Ubuntu run still counts against Alpine.
Old stats files without the field sum as 0. Two test cases, one per
direction; replaying the run's 40 artifacts with the field filled from the
logs gives `5949 / 5949, +0 ✓`.

**How to apply:** a parity -1 or -2 with `failed=0` everywhere is a retry,
not a regression — check for `flaky` before touching a skip-list (which is
jean's call anyway). This is the second gate-arithmetic red after #207's
node-version rows; neither was a browser gap.
[[project_pw_test_annotations_shape_conformance]]
