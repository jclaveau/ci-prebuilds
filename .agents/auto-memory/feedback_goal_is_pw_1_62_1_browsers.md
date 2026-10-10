---
name: feedback_goal_is_pw_1_62_1_browsers
description: HARD SCOPE — the goal is conformance + perf >= parity for the browsers PW 1.62.1 ships (chromium/firefox/webkit 2336), driven by the 1.62.1 client; never build a browser from a later PW release's patch series, never bump PW_VERSION as a fix
metadata:
  type: feedback
---

The goal is the browsers of PW 1.62.1: conformance against the 1.62.1 client and
its tests, and perf at or better than parity with official. Every lever must
keep that browser a 1.62.1 browser.

The drift that prompted this (2026-10-09): 1df1d2e moved PW_WEBKIT_PATCHES_REF to
1e9d2b1f to pick up the Skia compositor work for click_force perf. That series
turned out to be byte-identical to v1.64.0's (base 56453fdfe0, webkit 2370), so we
shipped a 1.64 WebKit driven by a 1.62.1 client. Auth changed to an array, the File
System API was turned on, and conformance went red (run 37841355978). I then patched
the 1.64 browser back toward 1.62.1 (b5d11a6), and offered a PW 1.64.0 bump as an
option. Both were further drift. jean: "the scope drifted completely".

**Why:** a perf lever that changes which browser we ship is not a perf lever.
**How to apply:**
- Before moving any pin (patch-series ref, base SHA, browser rev), check which PW
  release carries it. Compare its bootstrap.diff and browsers.json against the
  1.62.1 tag. If it belongs to a later release, it is out of scope.
- Perf gaps get closed by build or runtime levers on the 1.62.1-compatible tree.
- Never offer a PW_VERSION bump as a fix.
Related: [[feedback_never_skip_conformance_tests]], [[project_wk_1e9d2b1f_auth_protocol_skew]].
