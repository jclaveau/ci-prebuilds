---
name: chromium-aports-guard-branch-level
description: Alpine doesn't package every Chromium patch release, so the exact-equality aports guard was unsatisfiable by ANY commit — now compared on the first 3 dot-segments with a drift warning
metadata:
  type: project
---

**Alpine packages only some Chromium patch releases, so pinning
`ALPINE_APORTS_CHROMIUM_REF` to "the commit whose pkgver matches" can be
impossible.** PW 1.62 pins `151.0.7922.34`; aports went `150.0.7871.181` straight
to `151.0.7922.71` (65607f94), then `.108` (f649f59b). `.34` was never packaged,
and no published Playwright aligns either — 1.62.1 is latest and also pins `.34`.
That is what `auto-resolve-aports` has been failing on.

**Fixed `6c7c528`:** compare the first 3 dot-segments — the Chromium branch
(`151.0.7922`) — and emit a `::warning::` when the patch level differs, so the
skew is visible rather than silent. Same granularity `Dockerfile.apk`'s
drift-check already used.

**Safe because the input and the output are guarded separately:** this pin only
selects which musl patches get applied; `apply-and-build.sh` still fails further
down if the produced binary doesn't report `CHS_VER`. The input may drift within a
branch; the output may not drift at all.

Verified: `.71`/`.108` vs `.34` → warn, `150.x` vs `151.x` → still reject,
identical → silent.

**How to apply:** when picking an aports ref for a new Chromium pin, take the
closest patch release **on the same branch** (prefer just above PW's pin) to
minimise the skew between the patches and the source tree they're applied to.
Firefox's guard is separately major.minor-lenient — but note that leniency was
never the firefox bug; comparing the *wrong two things* was
([[project_pw_release_tag_pins_disagree]]).

Related: [[project_auto_resolve_aports_workflow]], [[project_alpine_no_historical_apk_archive]],
[[project_chromium_drift_warning_pattern]].
