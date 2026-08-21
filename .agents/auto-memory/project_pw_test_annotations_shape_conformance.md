---
name: project_pw_test_annotations_shape_conformance
description: before calling a conformance red "ours", read PW's own annotation — test.fail / host-gated it.skip decide whether upstream even runs it
metadata:
  type: project
---

Three WebKit reds, three different upstream situations:

- `tests/page/page-cache-storage.spec.ts` — `test.fail(browserName === 'webkit')`.
  PW declares it expected-to-fail; a PASS would be red for them.
- `tests/library/defaultbrowsercontext-2.spec.ts:285` — same scenario, persistent
  context, **no exemption**. This is the one red for us.
- `tests/library/permissions.spec.ts` camera/mic ×4 —
  `it.skip(isFrozenWebkit, 'Mock capture device support requires a newer WebKit')`,
  `isFrozenWebkit` = webkit && (debian11 | ubuntu20.04 | macOS<15).

**Correction 2026-08-21 — the camera bullet does NOT excuse the red.** PW's own
CI is ubuntu24.04, so `isFrozenWebkit` is false there and all four RUN and pass
upstream. "We cannot inherit a host-gated skip" describes the mechanism, not a
verdict: these are ours like the other two. The discriminator is in the shard
log — the granted AND the ungranted case both return `OverconstrainedError`
(the ungranted one should be `NotAllowedError`), i.e. getUserMedia fails before
the permission gate is consulted, so the device list is empty.

**Also**: PW 1.62.1 ships webkit **r2336, built from base `343e13bf`** (Apr), not
the `4d05d732` we build. PW moved its base 2026-07-24 and now ships r2355 built
from **exactly our base**, with a patch series older than our pin — so base and
patches are both exonerated and every red is ours (cmake flags, musl, strip,
runner env). `wk-conformance-residuals-probe.yml` (was
`wk-upstream-glibc-control.yml`) runs one script over three arms in one job:
ours, r2336, r2355.

Every lead below was measured out; the surviving root causes live in
[[project_wk_conformance_residual_aug2026]]. Do not re-raise:
- **`DEVELOPER_MODE`** — PW does build with it ON (`webkitdirs.pm:2911` pushes
  `-DDEVELOPER_MODE=ON` for non-Apple ports) while we set OFF, but its one
  visible consequence, `ENABLE_WPE_PLATFORM`, is not in play: PW's own r2336
  ships `libwpe` + `libWPEBackend-fdo` and no `libWPEPlatform`, the same legacy
  path we build.
- **Persistent `WebsiteDataStore` path** — our profile tree is structurally
  identical to upstream's.
- **`ENABLE_CONTEXT_MENUS`** — `WebKitFeatures.cmake:194` defines it
  `PRIVATE ON` globally; already on in our build.
- **The mock-capture preference default** — PW's own binary prints
  `- MockCaptureDevices` from `--features=help`, the same default as ours.

**How to apply:** grep the spec for `test.fail` / `it.skip` / `isFrozenWebkit`
BEFORE theorising about a musl gap, then check whether the gate actually fires
on PW's own CI host before treating it as an excuse. See
[[project_wk_conformance_residual_aug2026]].
