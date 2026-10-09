---
name: project_ff_libxul_twin_shipped
description: firefox now ships an unstripped libxul.so twin in /symbols (PR #284, merged), reusing the browser-perf-record symfs path instead of a separate nm census
metadata:
  type: project
---

Firefox perf-record profiles were unnamed (no symbol source). Chosen fix
(over building a separate nm census in apply-and-build.sh): reuse the same
`/symbols` twin path `browser-perf-record.yml` already has for
webkit/chromium, plus the `.text`-geometry guard from
[[project_perfrecord_symfs_geometry_guard]].

**PR #284, merged**: `bundle-dist.sh` copies `libxul.so` to a sibling
`firefox-symbols/` dir *before* the strip pass; the artifact stage's `FROM
scratch` COPYs it to `/symbols` alongside the normal `/firefox` output —
shipped consumer bytes unchanged, symbols only reach the perf-record image.
Triggered a full cold firefox rebuild on push to main (scripts are hashed
into the prebuilt base) — ~5-6h — followed by promote-firefox and a consumer
republish before a perf-record run can actually use
`symbols_image=ghcr.io/jclaveau/playwright-alpine-browsers:sha-<merge>
-f symbols_path=/symbols`.

**How to apply:** if a firefox perf-record run's symbols.md still comes back
unnamed after this merged, the twin path itself is probably fine — check
whether the consumer image was actually republished off the new main sha
first (promote + consumer touch), same failure mode as
[[project_source_patch_reaches_build_checklist]].
