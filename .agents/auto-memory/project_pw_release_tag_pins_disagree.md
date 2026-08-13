---
name: pw-release-tag-pins-disagree
description: Playwright's browsers.json and browser_patches/UPSTREAM_CONFIG.sh can pin DIFFERENT firefox versions at the same release tag — v1.60.0 says 150.0.2 but builds 147.0.1; v1.62.0 is consistent
metadata:
  type: project
---

**Playwright's own two firefox pins can disagree inside one release tag.**

```
v1.60.0  browsers.json  rev 1522 / browserVersion 150.0.2
         UPSTREAM_CONFIG.sh BASE_REVISION 4eb5a4f7 → version.txt 147.0.1   ✗
v1.62.0  browsers.json  rev 1538 / browserVersion 153.0
         UPSTREAM_CONFIG.sh BASE_REVISION f1b6c0f8 → version.txt 153.0     ✓
```

`apply-and-build.sh` clones `BASE_REVISION` (deliberately — the release tarball
diverges enough that PW's bootstrap.diff fails hunks), so at 1.60 it faithfully
built **147.0.1** and it shipped as `ff-150.0.2` for months. The old aports guard
compared pkgver against `browsers.json` — two pins that both said 150.0.2 — so it
passed, and 3h10m later produced the wrong browser. Nothing compared the source
tree to anything until the runtime perf probe printed `browser.version()` next to
the official image's.

**Fixed (220df1f):** right after checkout, `browser/config/version.txt` is asserted
against `browsers.json`'s browserVersion, on major.minor like the aports guard.
Fails in ~4 min instead of 3h10m, naming the SHA and both versions.

**How to apply:**
- Do not chase a browserVersion PW never coherently published. The 150.0.2 musl
  build was unreachable: no PW ref pairs 150.0.2 patches with a 150.0.2 tree.
  Moving to a self-consistent PW release is the fix, not hunting a BASE_REVISION.
- Check both pins before adopting any PW version: `browsers.json` browserVersion
  vs `raw.githubusercontent.com/microsoft/playwright/v<X>/browser_patches/firefox/UPSTREAM_CONFIG.sh`
  → that SHA's `browser/config/version.txt`.
- PW rolls `UPSTREAM_CONFIG.sh` only on explicit "roll to rNNNN" commits, so the
  patches tree lags published browser builds between rolls — that lag IS the bug.

Related: [[project_version_tag_never_verified]], [[project_ff_prebuilt_base_pin_only_tag_staleness]],
[[project_ff_build_two_pass_cbindgen]].
