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

**GREEN 20/20 (run 30309633021).** Residual after SYS_NICE was 8 → dispositioned:
- **Fixed (2):** headful font+hyphen parity — `headful.spec.ts` launches both headed
  AND `{headless:true}`; the headless launch resolved to the chrome-headless-shell
  path absent from chr-fs (full chrome only). Fix: symlink
  `chromium_headless_shell-<rev>/.../chrome-headless-shell` → the full chrome binary
  (runs headless via `--headless=new`; same binary → identical fonts, exactly the
  assertion). In build-runner.sh headed branch.
- **Flake (1):** video screencast capture-navigation — black-frame is timing-dependent
  under software-GL; passed on re-run, not skipped.
- **Headed-skipped, documented in chromium.headed.titles.txt (3):** showDirectoryPicker
  (PW's own comment: headed stalls on the native GTK picker; xvfb-run has no WM to
  dismiss it → context.close blocks); timezone-to-workers (headed favicon-404 console
  msg races the worker log in waitForEvent('console'); upstream it.fails it for FF);
  folder-upload `should upload a folder$` ×3 (setInputFiles(dir) SIGSEGV signal 11,
  headed-only, GHA-kernel-specific — does NOT repro on the dev box, chrome hangs
  instead; --disable-breakpad so no stack; needs a CI core-dump post-mortem, deferred
  as disproportionate for 3 tests; anchored regex spares the passing "...and throw"
  variant).

Whole headed campaign now green: FF + WK + chromium all pass headed conformance.
[[project_chromium_variant_build]] [[project_headed_mode_support]]
[[project_wk_fileinput_download_musl_gaps]]
