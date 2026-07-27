---
name: project_chromium_headed_dcheck_sys_nice
description: Headed chromium (chr-fs) conformance browser-deaths were a DCHECK_ALWAYS_ON + setpriority-EPERM crash, fixed by --cap-add SYS_NICE — NOT the GPU-process SIGABRT that looked like the cause.
metadata:
  type: project
---

Headed chromium (chr-fs full-chrome) PW conformance had ~23 deterministic
"Target page/context/browser has been closed" failures per shard (navigation,
cross-process iframes, base-url, cookies) — 0/20 shards green.

**Root cause (source-verified):** chr-fs is built with `DCHECK_ALWAYS_ON=1`.
Chrome raises a foreground renderer's priority via
`setpriority(PRIO_PROCESS, ..., <lower nice>)` (base/process/process_linux.cc:201),
which returns **EPERM** in a container **without CAP_SYS_NICE**. The
`DPCHECK(result == 0)` is **FATAL** in this build (release chrome silently
ignores the failure) → browser **SIGABRT** on every new-renderer op. Fix =
`--cap-add SYS_NICE` on the conformance container (pw-conformance.yml, gated to
`BROWSER=chromium`). 0→15/20 shards green immediately.

**GPU-process SIGABRT was a RED HERRING.** The logs are full of
`Exiting GPU process due to errors during initialization` (ANGLE→Vulkan→SwiftShader)
+ `Received signal 6` — but that GPU-process exit is BENIGN on headed chromium
(chrome continues, ~270 tests/shard pass through it). Two fixes proved it inert:
`vulkan-loader` (C) and `--disable-gpu` (B, drove GPU-exit count to 0) BOTH left
pass/fail **byte-identical**. Don't chase the GPU-process exit; grep the browser
stderr for the FATAL/DCHECK/`Received signal 6` line, not the viz_main_impl noise.

**Retry-line inflation trap:** counting `› spec.ts:NN › title` across shard logs
triple-counts (each fail + 2 retries) AND catches retry-progress lines → I
mis-sized it as "3062 fails / half the suite / systemic". Real = ~23/shard.
Use the authoritative numbered failure list (`^\s*N) [chromium-...]`), dedup.

**Residual after SYS_NICE (15/20):** 8 headed-specific tests, none previously
skipped — folder-upload ×3 (browsertype-connect launchServer/run-server,
page-set-input-files), headful font/hyphen parity ×2 (headed-only tests),
video screencast capture-navigation, timezone-to-workers, showDirectoryPicker
crash. Triage pending (fix vs headed-skip-list). [[project_chromium_variant_build]]
[[project_headed_mode_support]] [[project_wk_fileinput_download_musl_gaps]]
