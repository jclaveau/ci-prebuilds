---
name: project_aports_pkgver_rule_drift
description: the chromium pkgver rule lived in three files and two drifted to a stricter form than the build enforces, making any PW bump structurally red
metadata:
  type: project
---

`apply-and-build.sh` compares aports' chromium pkgver to PW's pin on the first
THREE dot-segments, deliberately, and says why in its own comment: Alpine
packages only some patch releases (150.0.7871.181 straight to 151.0.7922.71)
while PW pins 151.0.7922.34, so exact equality is unsatisfiable by ANY aports
commit and no published Playwright aligns either.

Two other places claimed in their comments to "mirror apply-and-build.sh's
pkgver check" and both still did STRICT equality:
`tests/aports/test-versions-env-consistency.sh` and the `auto-resolve-aports`
pre-flight. Neither followed when the real guard was relaxed, so the 1.62.1
bump could not go green no matter which SHA was pinned — structurally red
rather than wrong.

Now one file owns it: `chromium-headless-shell/scripts/aports-pkgver.sh`,
sourced by all three. It returns a STATUS rather than printing (0 exact, 1
same branch with patch drift, 2 different branch) because the callers speak
differently — GitHub annotations in two, plain stderr in the test — and
forcing one voice is what would make someone re-implement it again. It ships
into the producer image for free: `Dockerfile.setup` copies the whole scripts
dir and `apply-and-build.sh` already sources a sibling. Covered by
`tests/aports/test-aports-pkgver.sh`, 9 cases.

**Also found:** `auto-resolve-aports` substitutes only the SHA when it bumps
the pin, leaving the trailing `# chromium <version>` comment describing a
different commit. Fixed to move both.
[[feedback_reuse_source_of_truth_combiner]].
