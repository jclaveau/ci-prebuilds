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

Leads, in order of strength:
- **`DEVELOPER_MODE`**. `Tools/Scripts/webkitdirs.pm:2911` pushes
  `-DDEVELOPER_MODE=ON` for every non-Apple port, and PW builds through
  `build-webkit` — so their WPE build has it ON while `cmake-flags.overlay`
  sets `-DENABLE_DEVELOPER_MODE=OFF`. Same class of divergence we have been
  closing one option at a time (orientation, WebRTC).
- Persistent `WebsiteDataStore` path for CacheStorage.
- NOT `ENABLE_CONTEXT_MENUS` — checked, `WebKitFeatures.cmake:194` defines it
  `PRIVATE ON` globally, so it is already on in our build.
- NOT the mock-capture pref: `MockCaptureDevicesEnabled` defaults false on every
  port, PW never sends the `Page.overrideSetting`, passes no launch arg, and
  `bootstrap.diff` contains no mock wiring — so whatever gives upstream its
  devices is something else.

**How to apply:** grep the spec for `test.fail` / `it.skip` / `isFrozenWebkit`
BEFORE theorising about a musl gap, then check whether the gate actually fires
on PW's own CI host before treating it as an excuse. See
[[project_wk_conformance_residual_aug2026]].
