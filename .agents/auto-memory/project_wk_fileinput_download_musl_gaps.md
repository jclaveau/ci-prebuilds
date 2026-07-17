---
name: wk-fileinput-download-musl-gaps
description: WebKit-on-Alpine 3 PW conformance fails (upload-folder, lastModified, download) root-caused to a conformance-runner bwrap-sandbox env-var TYPO — a config bug, NOT a WebKit source/musl bug
metadata:
  type: project
---

3 WK conformance tests failed as bucket-C un-skips (iter 29565116253):
`should upload a folder` (webkitRelativePath="" for every file),
`should preserve lastModified timestamp` (File.lastModified ≈now not source
mtime), `should save downloads to artifactsDir` (download.path() → "No such
file"). Symptoms first looked structural.

**ROOT CAUSE (3-agent source dive: PW-core + WebKit@SHA + build config):** NOT a
WebKit source bug and NOT musl — a **conformance-runner config typo**. All 3 are
browser-side FS ops (PW-core JS is identical to chromium, which passes these on
Alpine). The conformance runner left WebKit's **bwrap sandbox LIVE**:
`pw-conformance.yml` disabled it with the misspelled `WEBKIT_DISABLE_SANDBOX=1`
instead of the upstream `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` the smoke jobs
use (PW-core doesn't read the short name either). The `--cap-add SYS_ADMIN` in
the same block PROVES bwrap runs (needs it for userns). A live bwrap namespaces
the FS and doesn't mount PW's host tmp dirs → WebProcess can't stat upload
sources (→ `DirectoryFileListCreator` skips the dir branch → empty relativePath;
`fileModificationTime` nullopt → `File::lastModified()` falls back to
`WallTime::now()`) and NetworkProcess can't `g_file_create` the download
destination. Ubuntu-WK baseline passes all 3 → config-not-source, confirmed.

**FIX:** corrected the env var in `pw-conformance.yml` (→
`WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` + `WEBKIT_FORCE_SANDBOX=0`, matching
smoke) + un-skipped the 3 titles. Validating in a follow-up WK conformance run
(obj cache warm from iter 29565116253 → fast rebuild). If any still red, the
residual is the musl `std::filesystem` seam (WTF `FileSystem.cpp`
`last_write_time`/`listDirectory`/`fileType` swallow-on-error) — restore that
title then.

**How to apply:** WebKit sandbox-disable env var is ALWAYS the `_THIS_IS_DANGEROUS`
spelling (+ `WEBKIT_FORCE_SANDBOX=0`); the short name is a no-op. Any WK file-I/O
oddity in a container → check bwrap is actually disabled before blaming musl or
WebKit source. Extends [[project_webkit_smoke_sandbox_strip_layers]]. Related:
[[webkit-alpine-branch-c]], [[conformance-only-dispatch-gap]].
