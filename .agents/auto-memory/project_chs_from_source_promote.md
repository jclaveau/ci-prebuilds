---
name: project_chs_from_source_promote
description: chs-<rev> (what the alpine-*-playwright consumer COPYs) is the canonical chromium tag. From-source (conformance-grade) lives at chs-fs-*; the superseded apk build owns chs-apk-<rev>. promote-chromium-from-source.yml retags chs-fs → chs-<rev> with NO rebuild.
metadata:
  type: project
---

**Tag ownership (after PR #85, 2026-07-29):**
- `chs-<rev>` / `chs-<ver>` / `chs-latest` = **from-source** chromium (conformance-grade).
  Single writer: `.github/workflows/promote-chromium-from-source.yml`.
- `chs-fs-sha-*` / `chs-fs-edge` = raw from-source finalize output (per-run).
- `chs-apk-<rev>` / `chs-apk-<ver>` = the SUPERSEDED apk fast-path (task #13
  UA-stylesheet bug, conformance-limited). `promote-chromium-headless-shell` was
  retired to this namespace so exercising the apk escape hatch can't clobber
  canonical `chs-<rev>`.

**The consumer NEVER builds chromium** — `Dockerfile.alpine` only
`COPY --from=ghcr…:chs-<rev>`. So it always reuses whatever `chs-<rev>` points at,
zero rebuild. To make it from-source: `imagetools create chs-fs-edge → chs-<rev>`
(a retag, seconds) — the from-source binary already exists, no ~13h build needed.
`promote-chromium-from-source.yml` is `workflow_dispatch` (`source_tag`,
`pw_version`); resolves rev/ver from PW browsers.json; dual-registry (GHCR + DH).

**Reuse-if-exists rule** (jean drove this): the from-source build is keyed by
chromium **rev** (which IS the PW-version-resolved id — same rev across PW
versions = reusable). To avoid the [[project_ff_prebuilt_base_pin_only_tag_staleness]]
trap, a future reuse-guard should key `chs-fs-<rev>-<recipehash>` (rev + hash of
gn-args/patches/scripts) so a recipe change forces a rebuild.

**After a promote, the consumer picks it up on the next main push** (build bakes
chs-<rev> at build time) — watch for buildx COPY-cache reusing the old layer;
verify the shipped `:latest` bakes from-source, not stale apk.
[[project_pw_version_aware_chs_rev_chain]] [[project_chromium_from_source_split_build]]
