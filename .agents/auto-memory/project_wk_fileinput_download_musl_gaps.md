---
name: wk-fileinput-download-musl-gaps
description: WebKit-on-Alpine file-input fails (upload-folder, lastModified) were a conformance-runner bwrap-sandbox env-var TYPO — FIXED, recovered. Download-to-artifactsDir is a separate residual WebKit soup download-write bug.
metadata:
  type: project
---

3 WK conformance tests failed as bucket-C un-skips (iter 29565116253). A 3-agent
source dive (PW-core + WebKit@SHA + build config) split them into TWO causes:

**Cluster A — file-input metadata (upload-folder + lastModified): FIXED, RECOVERED.**
`should upload a folder` (webkitRelativePath="" for every file) and `should
preserve lastModified timestamp` (File.lastModified ≈now not source mtime) were
caused by the conformance runner leaving WebKit's **bwrap sandbox LIVE** —
`pw-conformance.yml` used the misspelled `WEBKIT_DISABLE_SANDBOX=1` instead of the
upstream `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` the smoke jobs use (PW-core
doesn't read the short name either; the `--cap-add SYS_ADMIN` in the same block
proved bwrap ran). A live bwrap namespaces the FS and doesn't mount PW's host tmp
dirs, so the WebProcess couldn't stat upload sources → `DirectoryFileListCreator`
skips the dir branch (empty relativePath) + `fileModificationTime` nullopt →
`File::lastModified()` falls back to `WallTime::now()`. Fixed the env var
(→ `_THIS_IS_DANGEROUS` + `WEBKIT_FORCE_SANDBOX=0`); **validated iter 29619124025
— both now PASS, un-skipped permanently.**

**Cluster B — download-to-artifactsDir: RESIDUAL, still skipped.** `should save
downloads to artifactsDir` STILL fails after the sandbox fix (same
`download.path: … No such file or directory` at `artifacts/<uuid>`) — so it's
NOT the sandbox. Real WebKit soup download-write bug on musl/WPE: in
`NetworkDataTaskSoup::download()` either the automation download dir isn't
`makeAllDirectories`'d before `g_file_create`, or `g_file_move` (intermediate
`.wkdownload` → final) fails EXDEV across the container's tmpfs/overlay mounts.
DownloadProxy destination = `pathByAppendingComponent(downloadPathForAutomation(),
uuid)`. Needs a WebKit source patch — kept as a title-skip in webkit.titles.txt.

**How to apply:** WebKit sandbox-disable env var is ALWAYS `_THIS_IS_DANGEROUS`
(+ `WEBKIT_FORCE_SANDBOX=0`); the short name is a no-op. Any WK file-I/O oddity
in a container → check bwrap is actually disabled BEFORE blaming musl/WebKit.
Download residual dig-site: `NetworkDataTaskSoup.cpp` download()/didFinishDownload
(strace openat/renameat2 for ENOENT vs EXDEV). Extends
[[project_webkit_smoke_sandbox_strip_layers]]. Related: [[webkit-alpine-branch-c]],
[[conformance-only-dispatch-gap]].
