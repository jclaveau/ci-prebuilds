---
name: version-tag-never-verified
description: Every `<browser>-<version>` tag is derived from Playwright's pin, never from the artifact — the four places that now assert the binary matches, added 2026-08-12/13
metadata:
  type: project
---

**A version tag in this repo is a claim derived from a pin, not a measurement of
the artifact.** `ff-<ver>` / `chs-<ver>` / `wk-<ver>` all come from
`browsers.json`, so a stale or wrong binary publishes under a correct-looking tag.
That is how `ff-150.0.2` pointed at Firefox 147.0.1 (see
[[project_pw_release_tag_pins_disagree]]) — and re-promotion kept refreshing the
tag over the same wrong artifact, because promote copies a digest and asserts
nothing.

**Four assertion sites now close it:**

| where | asserts |
|---|---|
| firefox Tier-1 (`b3897c8`) | `Mozilla Firefox <browserVersion>` exactly — was `[0-9]+\.` and waved anything through |
| chromium-apk Tier-1 (`b0af912`) | the pinned `chromium_version` — was `HeadlessChrome\|Chromium` |
| webkit Tier-2 smoke (`b0af912`) | `browser.version()` vs `EXPECTED_WEBKIT_VERSION`, **required** not skip-if-unset; `promote-webkit` needs this job so it gates the tag. WebKit has no `--version` binary, so the smoke is the only possible site |
| `promote-chromium-from-source.yml` (`b0af912`) | its own Tier-1 against the source image before retagging. It had only `manifest inspect` — proves a manifest exists, not that it is this version — and it owns the canonical `chs-<rev>`/`chs-latest` tags the consumer COPYs |

Plus the consumer job `test-playwright-browser-versions` (TP): every staged
browser vs the image's own `browsers.json`, catching a stale `CHS_REV`/`FF_REV`/
`WK_REV` build-arg — PW resolves a browser by DIRECTORY NAME, so a wrong rev is
found, launched and never questioned. **Deliberately NOT in `promote`'s `needs:`**
while the firefox gap is open; fold it in once the pins are reconciled.

**How to apply:** any new producer or promote path must verify the artifact, not
the pin. `promote-firefox` needed no change only because it `needs: build-firefox`
and that job's Tier-1 now asserts — check that inheritance before adding a promote.

Related: [[project_chromium_webkit_base_tag_audit_safe]], [[project_conformance_build_triage]].
