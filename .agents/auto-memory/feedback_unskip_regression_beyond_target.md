---
name: unskip-regression-beyond-target
description: A blunt config/pref change to recover skipped tests can REGRESS tests it never targeted; the dispatch-validates loop catches it, and reverting a net-negative beats keeping it. Check red shards for collateral, not just the un-skipped titles.
metadata:
  type: feedback
---

When attacking a conformance-skip cluster with a global config/pref change (not a
narrow per-test fix), the change can break tests OUTSIDE the target set. Reverting
the whole change beats keeping a net-negative.

**Why:** 2026-07-19, disabling FF Fission (`fission.autostart=false`) to recover
cross-process-iframe tests (Juggler's single-process frame walk can't bridge OOP
iframes) DID recover 3 targeted tests locally — but in full CI it also broke
`framenavigated on anchor URLs`, `mainFrame persist on cross-process navigation`,
`cross-process _blank target`, `networkidle in setContent` — tests that were
PASSING and were never un-skipped. Site-isolation is load-bearing for those.
Net-negative → reverted the whole commit.

**How to apply:**
- A global toggle (a browser pref, a build flag, a feature disable) that "fixes"
  a cluster is a semantic change with blast radius — assume collateral until CI
  proves otherwise. A narrow per-title un-skip is safe; a `pref(...)` /
  feature-disable is not.
- When a dispatch reds, read the failing test NAMES, not just the count — if
  reds include tests you didn't touch, the change regressed and should be
  reverted, not surgically trimmed.
- Prefer the narrowest fix (per-test un-skip, runner apk/env that only ADDS a
  capability like gst plugins or ffmpeg-libs) over a behavior toggle. Additive
  runner-config (icu-data-full, ffmpeg-libs, GST_PLUGIN path) has no blast
  radius; a pref that changes process/isolation model does.

Related: [[project_wk_media_gst_registry_env]] (additive env, zero blast radius,
worked), [[feedback_config_first_layered_diagnosis]].
