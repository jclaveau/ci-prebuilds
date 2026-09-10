# playwright-pins — PW versions, browser revs, aports pins, renovate

Full hooks for this area. The routing keys live in `.agents/auto-memory/MEMORY.md`; the memories themselves in `.agents/auto-memory/<slug>.md`.

- [PW release tags can pin two different firefox versions](project_pw_release_tag_pins_disagree.md) — v1.60.0 browsers.json 150.0.2 vs UPSTREAM_CONFIG 147.0.1; we built and shipped 147.0.1 as ff-150.0.2; v1.62.0 is consistent
- [WebKit version assertions](project_webkit_version_assertions.md) — `browser.version()` is a hardcoded playwright-core constant (vacuous); real signals = `SET_PROJECT_VERSION` (2.53.1→2.53.3) at source-prep + libWPEWebKit so-version (1.10.0→1.10.2) at smoke
- [The aports pkgver rule had drifted in two of three copies](project_aports_pkgver_rule_drift.md) — mirrors claiming to mirror apply-and-build.sh kept strict equality after it went branch-level, making any PW bump structurally red; now one sourced file + unit test
- [Version tags are derived from pins, never verified](project_version_tag_never_verified.md) — the four assertion sites added (ff/chs Tier-1, wk smoke, promote-only retag) + the consumer check
- [PW 1.62 requires WebKit 26.5](project_wk_pw162_requires_265.md) — 26.4+1.62 = 5017 conformance failures vs 169 for our patched 26.5 build, 168 a strict subset; the residual is the PW bump, 16 are the absent GTK port, 1 is ours (heap.spec dispatcher leak)
- [chromium aports guard is branch-level, not exact](project_chromium_aports_guard_branch_level.md) — Alpine skips patch releases so exact equality was unsatisfiable; first 3 dot-segments + drift warning
- [FF_REV has no Renovate manager](project_ff_rev_has_no_renovate_manager.md) — CHS_REV and WK_REV are tracked, FF_REV is not; that is why ff-1522 went stale and main's version assert is red; PR #73 bumps PW without any of the three revs
- [A Playwright bump moves five things](project_pw162_matched_set.md) — the version, three hand-maintained consumer revs, two aports pins, plus three webkit build-side vars; FF_REV had no Renovate manager; the version assert is vacuous for webkit
- [Renovate topology + automerge:true is GLOBAL](project_renovate_topology.md) — customManagers per ARG, lockstep groupNames (PW, pnpm), GHCR `chs-NNN` consumer fallback via extractVersionTemplate; automerge:true is GLOBAL across all categories — user iterated 3× before settling; don't re-scope
- [WebKit smoke camera assertion needs PW 1.62](project_wk_smoke_camera_needs_pw162.md) — "Unknown permission: camera" is PW 1.60's webkit map lacking it, not a browser gap; the contextmenu fix (PR #98) IS validated in the same smoke
- [Chromium drift-warning pattern](project_chromium_drift_warning_pattern.md) — 3-tier drift surfacing: producer bakes `.version-drift-warning` → consumer echoes to stderr at build → on-demand prepends `:warning:` block to issue comment
- [PW-version-aware CHS_REV chain](project_pw_version_aware_chs_rev_chain.md) — PW → browsers.json → chs_rev → producer tag → consumer CHS_REV ARG; threaded through on-demand → test-and-publish → Dockerfile.alpine with pre-flight `docker manifest inspect`
- [Vanilla-config test PW alignment](project_vanilla_config_test_pw_alignment.md) — `pnpm add -D @playwright/test@$(playwright --version | awk '{print $2}')`, never unversioned (resolves to LATEST and breaks non-default PW builds)
