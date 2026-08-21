---
name: project_ff_rev_has_no_renovate_manager
description: renovate tracks ARG CHS_REV and ARG WK_REV but NOT ARG FF_REV — the mechanism behind ff-1522 going stale and main's version assert being red
metadata:
  type: project
---

`renovate.json`'s customManagers cover `ARG CHS_REV=` and `ARG WK_REV=` and
**nothing matches `ARG FF_REV=`**. Firefox's consumer rev therefore drifts
silently while chromium's and webkit's are tracked — which is how
`playwright/Dockerfile.alpine` sat at `FF_REV=1522` long enough for the
version assert to go red on main
([[project_version_tag_never_verified]], [[project_pw_release_tag_pins_disagree]]).

State on 2026-08-21, main and `renovate/playwright` identical:

| ARG | pinned | PW 1.60 wants | PW 1.62.1 wants | our tag exists? |
|---|---|---|---|---|
| `CHS_REV` | 1223 | — | **1234** (151.0.7922.34) | yes |
| `FF_REV` | 1522 | 150.0.2 (ships 147.0.1) | **1538** (153.0) | yes |
| `WK_REV` | 2287 | — | **2336** (26.5) | yes |

**PR #73 "chore(deps): update playwright to v1.62.1" does not bump any of
them**, so merging it as-is leaves the version assert red — it would then fail
on 153.0-expected-vs-147.0.1-staged instead of 150.0.2. All three target
images are already published, so the fix is three digits.

**How to apply:** add the missing `ARG FF_REV=` customManager alongside the
other two (same GHCR `ff-NNN` datasource shape as `chs-NNN`, see
[[project_renovate_topology]]), and bump all three revs in the same PR as any
Playwright bump — the pin and the SDK are a matched pair. Do not merge a PW
bump without them.
