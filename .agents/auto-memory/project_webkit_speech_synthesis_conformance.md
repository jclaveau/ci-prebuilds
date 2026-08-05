---
name: project_webkit_speech_synthesis_conformance
description: WebKit ENABLE_SPEECH_SYNTHESIS must stay ON — dropping flite fails modernizr Safari Desktop/Mobile Safari
metadata:
  type: project
---

`ENABLE_SPEECH_SYNTHESIS=OFF` (dropping the flite TTS engine + voice data, ~11 MB
per bundle) is **not** a usable size lever: Modernizr then reports
`speechsynthesis: false`, and `tests/library/modernizr.spec.ts` asserts the full
key map with `toEqual`.

- Measured in run 30898739850 (commit `66888f0`, branch
  `fix/finalize-overlay-stage-cache`): `conformance-webkit / shard 12` failed on
  exactly one key —
  `- "speechsynthesis": true` / `+ "speechsynthesis": false` — killing both
  `modernizr.spec.ts:35 Safari Desktop` and `:93 Mobile Safari`, retries
  included. Every other shard + the whole build chain was green.
- Those two suites had been deliberately un-skipped after the font fix that
  closed `unicoderange` ([[project_wk_webrtc_modernizr_resolved]]), so
  re-skipping them to buy 11 MB trades real coverage for very little.
- Reverted in the follow-up commit: `flite-dev` back in `Dockerfile.source-prep`,
  `-DENABLE_SPEECH_SYNTHESIS=ON` in `cmake-flags.overlay`, and
  `force_speech_synthesis_off` dropped from `scripts/prep-source.sh`.
- The other two levers from the same commit are clean and stay: WPE-only `wk-*`
  artifact and the consumer-side Mesa strip (~228 MB).

**Why:** the modernizr suites are a whole-feature-map contract, so any build-flag
that flips a single Modernizr key is a conformance regression, not a size win.

**How to apply:** before proposing a WebKit `ENABLE_*` flag as a size lever,
check whether Modernizr probes that feature — if it does, the flag is off-limits
unless you are willing to re-skip the two Safari UA suites.
