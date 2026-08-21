---
name: webkit-version-assertions
description: The WebKit smoke version check was vacuous (browser.version() is a hardcoded playwright-core constant); the real signals are SET_PROJECT_VERSION at source-prep and the libWPEWebKit so-version at smoke
metadata:
  type: project
---

**`browser.version()` does not read the browser.** `playwright-core` carries
`const BROWSER_VERSION = '26.5'` in `webkit/wkBrowser.ts` and returns it verbatim;
`EXPECTED_WEBKIT_VERSION` comes from the same package's `browsers.json`. The old
smoke assertion therefore compared PW against itself and passed for whatever
WebKit we built — it could never catch a mislabelled artifact. It works for
Firefox only because Firefox reports its version from the binary. `26.5` is a
Safari marketing version with no counterpart anywhere in the WebKit sources.

**Two checks that can actually fail**, one on each side of the build:

- `prep-source.sh` reads `SET_PROJECT_VERSION` from the cloned+patched tree and
  asserts it against `PW_WEBKIT_PROJECT_VERSION`. Moves with the base:
  343e13bf = **2.53.1**, 4d05d732 = **2.53.3**. Fails in the 8-minute source-prep
  job, so an undeclared base move never reaches a build.
- `smoke/launch.cjs` reads the so-version off the shipped `libWPEWebKit` and
  asserts `PW_WEBKIT_WPE_SOVERSION`. WebKit's
  `CALCULATE_LIBRARY_VERSIONS_FROM_LIBTOOL_TRIPLE(WEBKIT c r a)` renders as
  `.so.<c-a>.<a>.<r>`: (11 0 10) → **1.10.0** at 343e13bf, (11 2 10) → **1.10.2**
  at 4d05d732. This is the one value only the built binary supplies.

Both refuse to run against an unset expectation instead of degrading silently —
that is precisely what made the original worthless. Verified non-vacuous: the
source gate passes on 2.53.3 and fails on both a stale 2.53.1 and an unset var.

Bump BOTH constants whenever [[project_pw_patch_series_base_pairing]] moves.
Related: [[project_version_tag_never_verified]].
