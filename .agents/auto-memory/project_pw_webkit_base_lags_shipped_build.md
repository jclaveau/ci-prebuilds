---
name: pw-webkit-base-lags-shipped-build
description: PW's browser_patches/webkit/UPSTREAM_CONFIG.sh names a WebKit older than the webkit build it ships, so building at the pinned SHA cannot produce a browser its own client can drive — root cause of the PushAPIEnabled newPage failure
metadata:
  type: project
---

**`browser_patches/webkit/UPSTREAM_CONFIG.sh` at a PW release tag is not the
tree PW built its shipped WebKit from.**

For v1.62.0 (webkit rev 2336, browserVersion 26.5):

```
tag v1.62.0 UPSTREAM_CONFIG BASE_REVISION  343e13bf  (2026-04-28)
roll c623920f moved it to                  4d05d732  (2026-06-11)
  ...and landed 44 min BEFORE the tag, yet is not in it (release branch cut earlier)
WebKit 5e67bf8293 (2026-07-13) upstreams 5 of PW's settings + adds PushAPIEnabled
PW's webkit-2336 build is dated 2026-07-21 → necessarily past 5e67bf8293
```

Symptom: `playwright-core@1.62.0` sends **7** `Page.overrideSetting` calls while
creating a page, unguarded, so one rejection fails `newPage`:

```
browserContext.newPage: Protocol error (Page.overrideSetting):
Unknown setting: PushAPIEnabled
```

**The authority is `protocol.json` inside PW's own published zip** —
`cdn.playwright.dev/dbazure/download/playwright/builds/webkit/<rev>/webkit-ubuntu-24.04.zip`.
It lists **21** settings; pinned base + the tag's `bootstrap.diff` yields **20**.
Do not infer this from `strings` on the library (`PushAPIEnabled` appears there
as a WebPreferences key regardless) and do not infer the patch's additions from
a grep ([[feedback_complete_set_needs_the_real_artifact]]).

**Fix:** `prep-source.sh` adds the one missing enum member + a
`setPushAPIEnabled(value.value_or(false))` case, PW's own idiom for the
neighbouring settings. Upstream's `overrideSettingByModifyingValue` route needs
yaml changes that collide with bootstrap.diff's five. Drop the block when PW
rolls past `5e67bf8293` — bootstrap.diff must then stop adding the five, so it
will be visible.

Same disease as [[project_pw_release_tag_pins_disagree]] (firefox), different
mechanism: there the two in-repo pins disagreed; here the in-repo pin lags the
artifact. Related: [[project_wk_pw162_requires_265]].
