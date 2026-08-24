---
name: project_pw162_matched_set
description: a Playwright bump moves five things, not one — the version, three consumer revs, two aports pins, and for webkit three more build-side vars
metadata:
  type: project
---

`test-playwright-browser-versions` was red on every main run for weeks. The
symptom named one thing; the fix needed five, each discovered only after the
previous one went green.

| moves with PW_VERSION | where | why |
|---|---|---|
| `CHS_REV` `FF_REV` `WK_REV` | `playwright/Dockerfile.alpine` | hand-maintained; PW locates a browser by DIRECTORY NAME, so a stale rev resolves happily and drives the wrong binary |
| `ALPINE_APORTS_REF` `ALPINE_APORTS_CHROMIUM_REF` | `versions.env` | the musl patch sets are per chromium/firefox BRANCH |
| `PW_WEBKIT_PATCHES_REF` `_PROJECT_VERSION` `_WPE_SOVERSION` | `versions.env` | the patch series and the WebKit base are a matched pair |

**`FF_REV` drifts because `renovate.json` has no customManager for it** —
`ARG CHS_REV=` and `ARG WK_REV=` are tracked, `ARG FF_REV=` was not. Added in
#99.

**WebKit is the hard dependency**, not a version detail: PW 1.62.1 sends
`Page.overrideSetting: PushAPIEnabled` on every `newPage` and no image built
from the old patch series understands it. Lowering `WK_REV` does not help —
older is worse. #99 shipped chromium+firefox with the two `[webkit]` tests
skipped on alpine (#100); #101 rebuilds WebKit properly.

**The version assert cannot catch the WebKit case.** `browser.version()` for
webkit is a hardcoded playwright-core constant, so `OK : webkit 26.5` is
vacuous. Only tests that drive the browser see it — which is why the smoke's
`EXPECTED_WPE_SOVERSION` check, reading the built libWPEWebKit's so-name, is
the one that matters. [[project_webkit_version_assertions]],
[[project_pw_release_tag_pins_disagree]].
