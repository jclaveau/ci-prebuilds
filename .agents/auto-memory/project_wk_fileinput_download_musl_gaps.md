---
name: wk-fileinput-download-musl-gaps
description: WebKit-on-Alpine fails 3 PW conformance tests (upload-folder, lastModified, download-to-artifactsDir) — deep-diagnosed to 2 root-cause clusters in WebKit automation file I/O, Alpine/musl-specific
metadata:
  type: project
---

3 WK conformance tests fail structurally on our WPE/GTK musl build (bucket-C
iter 29565116253). Deep-diagnosed from shard error bodies + A/B vs the Ubuntu-WK
baseline (same run, same PW WebKit SHA + patches — **Ubuntu passes all 3**, so
these are musl/our-WPE-build specific, NOT PW-upstream-known). Skip in
`webkit.titles.txt`. Two clusters, both needing a WebKit build/source fix (NOT
runner apks — icu/nss/gst apk probe didn't move them).

**Cluster A — automation file-input METADATA not propagated.** PW setInputFiles
injects via WebKit `Automation.setFilesForInputElement` (bypasses native picker);
file CONTENTS arrive but metadata drops:
- `should upload a folder`: all 3 files present but `webkitRelativePath===""` for
  each → Set collapses 3→1 (`{""}`). Retry also crashed WebProcess (Target
  closed / 30s timeout) — instability on top of the metadata bug.
- `should preserve lastModified timestamp`: `File.lastModified` ~170s late
  (≈ upload wall-clock, not source `stat` mtime) — File built from copy/now().
- Dig-site: WebKit `WebAutomationSession` file handling (relativePath + mtime).

**Cluster B — download-delegate PERSISTENCE.** `should save downloads to
artifactsDir`: `download.path()` → "No such file or directory" at
`artifacts/<uuid>` — download event fires + returns a path, but bytes never
written to the automation-designated dir.
- Dig-site: WebKit `DownloadManager` / `SandboxExtension` write path on musl/WPE.

**How to apply:** kept as title-skips (precise rationale in webkit.titles.txt
comment). To actually FIX: needs a local WebKit-WPE musl repro + trace of the
two dig-sites above — CI-only iteration is too slow (each WK build ~cold hours,
see [[conformance-only-dispatch-gap]]). Distinct from the WK codec structural
skip (media pipeline) and headed-GTK recursion. Related:
[[webkit-alpine-branch-c]], [[pw-conformance-scope-out-of-scope]].
