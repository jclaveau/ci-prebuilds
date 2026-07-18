---
name: wk-fileinput-download-musl-gaps
description: WebKit-on-Alpine file-input fails (upload-folder, lastModified) were a conformance-runner bwrap-sandbox env-var TYPO — FIXED. Download-to-artifactsDir was a missing-parent-dir bug — FIXED via a WebKit soup mkdir -p source patch (prep-source.sh).
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

**Cluster B — download-to-artifactsDir: FIXED 2026-07-18 (WebKit source patch).**
`should save downloads to artifactsDir` was NOT the sandbox (still failed after
the env-var fix). Root-caused via **local repro** (pulled `wk-sha-…` artifact →
built the conformance runner → ran the single test + strace): the failing op is
a **missing parent dir**, not EXDEV. The test passes a *user-provided*
artifactsDir (`testInfo.outputPath('artifacts')`); `outputPath` mkdirs only
`outputDir`, NOT the `artifacts/` subdir. PW's `browserType` mkdirs the download
dir ONLY on the auto-`mkdtemp` branch, not a caller-supplied one
(`browserType.ts:158-163`). WebKit's `NetworkDataTaskSoup::download()` opens the
destination with `g_file_replace`/`g_file_create` which do NOT mkdir -p → the
first open fails `G_IO_ERROR_NOT_FOUND` = "Error opening file …: No such file or
directory". **Proven**: injecting `fs.mkdirSync(artifactsDir)` into the test made
it PASS locally (4.7s). Fix = inject an idempotent
`g_file_make_directory_with_parents(g_file_get_parent(dest))` into
`download()` before the stream open — in `prep-source.sh` (awk, marker
`download destination parent`). Un-skipped in webkit.titles.txt; validates on the
next WK producer rebuild. (Ubuntu-WebKit passes this same test unpatched — its
build/env creates the dir; our musl build doesn't. Didn't fully resolve that
asymmetry; the mkdir -p is idempotent so it's safe either way.)

**How to apply:** WebKit sandbox-disable env var is ALWAYS `_THIS_IS_DANGEROUS`
(+ `WEBKIT_FORCE_SANDBOX=0`); the short name is a no-op. Any WK file-I/O oddity
in a container → check bwrap disabled first, THEN local-repro + strace before
blaming musl. Local-repro recipe: `docker pull` the `wk-sha-<sha>` artifact,
`build-runner.sh` (BROWSER=webkit IMAGE_REF=… PW_VERSION=… ARTIFACT_REV=2287),
bake a prepared image (clone+`npm ci`+`npm run build`), then
`npx playwright test tests/library/download.spec.ts --config=tests/library/playwright.config.ts
--project=webkit-library -g "<title>"` under strace — seconds per iteration.
Extends [[project_webkit_smoke_sandbox_strip_layers]]. Related:
[[webkit-alpine-branch-c]], [[conformance-only-dispatch-gap]],
[[feedback_config_first_layered_diagnosis]].
