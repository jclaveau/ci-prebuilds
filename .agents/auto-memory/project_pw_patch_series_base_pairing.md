---
name: pw-patch-series-base-pairing
description: PW's browser_patches bootstrap.diff and its UPSTREAM_CONFIG BASE_REVISION are a matched pair — applying the series to any other WebKit SHA fails ~46-49 of 897 hunks; move both together via PW_WEBKIT_PATCHES_REF
metadata:
  type: project
---

**`bootstrap.diff` only applies to the SHA its own `UPSTREAM_CONFIG.sh` names.**
Measured by fetching just the files the diff touches (358) at each candidate and
running `patch -p1 --dry-run`:

```
WebKit 4d05d732 (11 Jun, PW main's own base) →  0 failed hunks
WebKit 5e67bf8293 (13 Jul)                   → 46 failed hunks (of 897)
WebKit 524399615e24 (20 Jul)                 → 49
```

So **version parity with PW's shipped browser is not reachable**: their published
series is authored against 11 Jun, while `webkit-2336` was built in July from a
patch state they had not released. Our ceiling is their newest *released* series.

**The knob:** `PW_WEBKIT_PATCHES_REF` in `versions.env` selects the playwright ref
that `fetch-pw-patches.sh` pulls `UPSTREAM_CONFIG.sh` + `patches/` + `embedder/` +
`pw_run.sh` from (default `v${PW_VERSION}`). It is pinned to a commit, not a
branch, for reproducibility. `browsers.json` still comes from
`playwright-core@${PW_VERSION}` — revision/browserVersion must track the client
we ship (2336 / 26.5).

Moving it from the v1.62.1 tag (WebKit 343e13bf, 28 Apr) to main
(playwright c377b7f4 → WebKit 4d05d732) made two hand-backports redundant —
`snapshotRect` format/quality and the certificate CN summary — and they
self-disabled through their skip-if-present guards. Still needed after the move:
`closePage`, `PushAPIEnabled`, `setLanguages`.

Cost of the move: it exposed [[project_webkit_jsc_jit_pch_race]].
Related: [[project_pw_webkit_base_lags_shipped_build]],
[[feedback_prefer_upstream_base_move_over_backports]].
