---
name: project_wk_pgo_dud_dispatch_missing_flag
description: WK PGO run 36048405627 (redispatched 2026-09-24 19:28:42Z after the %m SIGBUS fix and the -disable-vp fix) omitted `-f webkit_pgo=on`, which defaults to off on `perf/wk-pgo` — 2h56 spent building plain non-instrumented WPE with zero PGO signal; both fixes remain UNPROVEN
metadata:
  type: project
---

The redispatch meant to exercise [[project_wk_pgo_multidso_sigbus_percent_m]]'s
`%m` fix (`1b1354d`) and the `-mllvm -disable-vp=true` fix (`95f8ef7`) never
ran Phase 0 at all. Its job log read `WK_PGO=off`: no instrumented ninja, no
smoke run, no corpus run, no `llvm-profdata merge` — just the plain
`cmake configure` → `ninja` → MiniBrowser path, byte-for-byte the normal
build. `webkit_pgo` is a `workflow_dispatch` input on `perf/wk-pgo` with
`default: 'off'`, and the redispatch command dropped `-f webkit_pgo=on`.

The run still finished 4h later as `failure`, on `perf-gate-webkit` — but
that red is the pre-existing [[project_wk_perfgate_libm_fmod_breach]]
(`libm_fmod` 1.052 vs the 1.03 tight ceiling), unrelated to PGO and already
waiting on jean's `loose`-margins ruling. It looked like a real signal on a
PGO candidate; it was actually the unrelated ratchet doing its job on an
artifact that happened to have no PGO in it.

**Why:** a workflow input with a non-obvious default silently changes what a
multi-hour dispatch actually tests. Nothing in the job's early log (stage
names, timing) distinguished a PGO Phase-0 run from a plain build until the
`WK_PGO=off` line was read directly — the run "looked" like it was doing
something for 2h56.

**How to apply:** before trusting a redispatch to exercise a specific fix,
read back the actual `-f` flags that will be sent (or the job's own
`Flags:` log line once it starts) — don't assume a prior dispatch's intent
carries forward. When re-dispatching `perf/wk-pgo` specifically, `-f
webkit_pgo=on` is mandatory every time; it does not persist across
redispatches. [[project_gha_dispatch_once_guard]]'s guard confirms *a* new
run landed, not that it landed with the right inputs — a missing flag is a
silent miscompile-of-intent, not a dispatch failure the guard would catch.

**2026-09-25 23:28Z — redispatched with the flag** on jean's go: run
`36201166501`, `perf/wk-pgo` @ 95f8ef7, `-f build_webkit=true -f webkit_pgo=on`.
This is the WK PGO baseline (first real Phase 0 with both fixes).

**Done-signal port, separate branch** `perf/wk-pgo-completion` @ d8663f1 (off
95f8ef7), pushed, NOT dispatched: train.html wraps Speedometer2.1's own
`benchmarkClient.didFinishLastIteration` (same-origin, no benchmark patch),
cap 10→25 min backstop, rounds logged as `GET /pgo-round?round=N&event=
start|done|cap|start-failed&ms=` into `$PGO_DIR/corpus-http.log` and printed;
build fails on 0 starts or any start-failed. Old page spun a tight loop on a
start failure (advance() immediately). Mirrors FF's c64d783 (run 36200910824).
Local harness: playwright-core from ~/dev/Prello/xano-lambda + cached
chromium_headless_shell-1217 with `--disable-gpu --in-process-gpu
--use-gl=disabled` (box GPU crash-loops otherwise); a stale http.server of mine
on the test port once silently ate all requests — check `ss -ltnp` first.

**Baseline result (36201166501, 95f8ef7, 09-26 05:34Z, EPYC 9V74):** Phase 0 RAN clean — ZINK vkCreateInstance error printed but harmless (7 profraw, no truncation, merge ok). BUT the corpus trained ~nothing: corpus total count 12.8M vs about:blank 3.9M (3.3x, barely past the ≥3x check), max function count 328k — a Speedometer run would be billions. Same 7 files after corpus as smoke. No request log in 95f8ef7, so why Speedometer never ran is unknown; d8663f1's /pgo-round log answers it. Despite the startup-only profile, ratchet vs promoted geo 0.941 (layout 0.577, goto_warm 0.831, dom_churn 0.934, launch 1.035); one draw. Gate red = libm_fmod 1.044 vs official alone (pre-existing, ratchet 1.000). ubuntu-chromium shard 18 red = isAlmostRed video test on official PW, not ours.

**Done-signal run (36242656232, d8663f1, 09-26, checked 2026-10-06):** all green
(smoke, conformance-webkit, perf-gate-webkit, runtime-parity) but
`promote-webkit` SKIPPED — its gate requires `github.ref == refs/heads/main`, by
design (branch dispatches publish only `wk-sha-<sha>`). The new round log
answered the baseline's question: `rounds started: 1, finished: 0` — Speedometer
round 1 never finished in the 1800s corpus budget (MiniBrowser TERMed), corpus
12.1M vs about:blank 3.9M, so the profile is still startup-only. Tally reads it
geo 0.81 vs we-latest 0.88 same job (nav 0.75 vs 0.85, render 0.66 vs 0.80),
one draw on EPYC 7763. Not merged; `webkit_pgo` defaults off, so merging alone
would not make main's builds PGO.

**Why round 1 never finished (diagnosed 2026-10-06 from the run's merged.profdata,
corpus-only — the script rm's the smoke profraws):** the instrumented WebProcess
CRASHED right after the first Speedometer test page (vanillajs TodoMVC) loaded.
Counts: `WTFCrashWithInfo(int,const char*,const char*)` 1 (a RELEASE_ASSERT /
CRASH_WITH_INFO), `WebProcessProxy::didClose` 1, `processDidTerminateOrFailedToLaunch`
1, `webkitWebViewWebProcessTerminated` 1, `WebPageInspectorController::pageCrashed` 1,
`ResponsivenessTimer::timerFired` 0 (not a hang); `DOMTimer::fired` 0, rAF service 0.
corpus-http.log: last request is vanillajs `app.js` at 15:36:59, then 30 min silence.
MiniBrowser --headless does not relaunch a dead WebProcess, and train.html's cap
timer lived in it, so no `cap` either. Not reproducible on the shipped
(non-instrumented) build: local train.html does 26 rounds / 15 min (python server,
default seccomp, with and without CPU rendering). The assert SITE is unknown — the
profile has no call graph and the instrumented .so is deleted at Phase 0 end.
Reading the profile needs llvm23 (`alpine:edge` + `apk add llvm23`); llvm-profdata-20
rejects the format.

Shipped b8c5e5b on perf/wk-pgo-completion (2026-10-06): Phase 0 runs one MiniBrowser per Speedometer suite (`train.html?suite=`), round-robin under PGO_CORPUS_SECONDS, PGO_SUITE_SECONDS cap each, a suite dropped after 2 crashes; `crash-report.so` (LD_PRELOAD) + `pgo-symbolize-crash.py` print the crash site in the job log. Local harness (shipped MiniBrowser): 21 suites done in 300 s, rc=0. Needs one dispatch with `-f webkit_pgo=on` — jean's go only.

Second dud, 2026-10-06: run 37442522967 (b8c5e5b) was dispatched with `-f webkit_pgo=on` but WITHOUT `-f build_webkit=true` (default 'false'), so it built nothing: resolve-pins + Ubuntu conformance only, 5 min, "success". BOTH flags are mandatory: `gh workflow run playwright-alpine-browsers.yml --ref <branch> -f build_webkit=true -f webkit_pgo=on`. Copy the line-39 command; never retype it.
Redispatched by jean 2026-10-06 11:27:07Z with both flags: run 37456486061 (b8c5e5b). Read Phase 0 log for the symbolized crash report and per-suite outcomes.

RESULT run 37456486061 (b8c5e5b, finished 2026-10-06 ~17:58Z): PGO WORKS on perf.
perf-gate-webkit ratchet (PGO candidate vs promoted, one runner): geomean 0.931,
layout 0.542, goto_warm 0.833, dom_churn 0.858, eval_rtt 0.955; parity geo 0.840.
Gate red on two rows, neither PGO's: parity libm_fmod 1.044 (branch is 45 behind
main, still has the 9M-iteration kernel — runtime-probe.cjs:196 — the 36M resize
lives only on main) and ratchet js_alloc 1.139 (cv 0.125 cand / 0.069 ref, noise row).
Phase 0: 18 SIGSEGV, fault_addr 0xffffffffffffffff, 17 suite-rounds never "done"
(every suite eventually; round 1 for jQuery/Vanilla*/Backbone/Elm/Flight*/AngularJS).
Symbolizer printed NO frames (only a false `str=` hit on rbp) — rip not inside any
file-backed exec mapping, likely JSC JIT code; crash dir gone with the build tree.
3073 profraw merged anyway. Next (jean's go): rebase onto main so libm_fmod uses 36M,
redispatch with the line-39 command; the crash needs rip/maps printed raw to read.
Done 2026-10-06 19:29Z on jean's go: branch rebased onto main (c7a2508; picks up the
36M libm_fmod kernel), +6ccf228 (symbolizer keeps anon mappings, prints raw regs,
rip/rsp owning mapping, stack-word counts per exec mapping; first report's exec maps
raw in the log). Redispatched with both flags: run 37519378656.
