---
name: project_ff_pgo_extended_corpus_jetstream_motionmark
description: 2026-09-25 IN PROGRESS — jean approved adding JetStream3 (Mozilla's own --extended-corpus flag, never flipped by us) and MotionMark (Mozilla's raptor fetch, repurposed for PGO training) to FF's PGO corpus, plus raising each item's fixed timeout to a real completion signal; DISPATCHED 2026-09-25 23:24Z run 36200910824 on c64d783 (d3156a6 footer-amended), branch perf/ff-pgo-corpus-completion off b8e2248, build_firefox=true
metadata:
  type: project
---

Follow-on to [[project_ff_pgo_corpus_append_experiment]] (#307, CLOSED as a
wash — appending our own probe kernels to Mozilla's corpus moved nothing).
Different hypothesis this time: not "train on the graded workload" but "use
the real third-party benchmark chromium's own PGO corpus trains, that
Mozilla's corpus already has a switch for and we never flipped."

**What each side trains on:**

| chromium `generate_profile.py` | Mozilla `build/pgo/index.html` | ours today |
|---|---|---|
| speedometer3 | Speedometer3, port 8000, 2 min | yes |
| jetstream3 | JetStream3, port 8001, 5 min, gated behind `extendedCorpus=true` | no |
| motionmark | not in Mozilla's PGO corpus (fetched only for raptor) | no |
| system_health | no analog | no |
| — | ~70 talos perf-reftests + sunspider, 2s each via `Quitter.quit()` | yes |

**JetStream3**: `profileserver.py` already wires it —
`js3_httpd = MozHttpd(port=8001, docroot=js3_dir)` gated on
`has_extended_corpus`, tarball pinned in
`taskcluster/kinds/fetch/benchmarks.yml`
(`https://github.com/WebKit/JetStream/archive/3967678fa8ab98d847ab33cf3728dba726fa854b.tar.gz`,
sha256 `d62e9dc22ae6b52b3d467a7fbd45689fbb77ddd57a4fd56422c0ffb022d4f9ee`).
We call `profileserver.py` directly (two-job split), skipping Mozilla's
`bootstrap_toolchain("pgo-extended-corpus")` (needs taskcluster, fails in
our container) — fetching the tarball ourselves in `firefox/scripts/apply-and-build.sh`
is the shorter path, not a workaround:
```diff
     ../mach python ../build/pgo/profileserver.py --binary "$SRC/$DIST/firefox"
+      --extended-corpus /work/pgo-extended-corpus
```
Did NOT confirm whether Mozilla's own shipping Linux builds set
`MOZ_PGO_EXTENDED_CORPUS=1` (gated on that string in
`build_commands.py:305`, mozconfig not located) — so this is "Mozilla
supports it and we never used it," not "we ship less corpus than release
Firefox."

**MotionMark**: WebKit's graphics benchmark (animated canvas/SVG/CSS,
scores sustained-complexity at 60fps — trains the paint/composite path).
Mozilla fetches it only for raptor (`?raptor` query param = the
Perfherder-reporting hook), not for PGO training — but it's the same pinned
fetch either way (`webkit/motionmark` be2a5fea, 576 KB, vs JetStream's 194
MB) and talos items already have a `tpRecordTime` completion hook to reuse.
Under Xvfb+llvmpipe it trains the *software* raster path — the one the
consumer image actually runs. Jean's "go" covered adding this too, not just
JetStream3.

**Cost, measured not estimated**: pulled run 35993882679's generate log —
whole profile run 8m46 (47 profraw, `merged.profdata` 97 MB), generate
stage 3h23. JetStream3's own `superExtendedTimeout` is 5 min →
generate ~3h28. MotionMark's 576 KB tarball is a cached Docker layer either
way.

**Target metric**: `js` row (`eval_rtt`, `js_alloc`) at 0.89–0.91 — the only
improvable non-control group. `input`/`click_force` stays structurally
unreachable (CDP-level, per [[project_ff_pgo_corpus_append_experiment]]).
`int_math`/`libm_fmod` stay held out as controls; JetStream/MotionMark don't
touch them.

**Carried over from #307 as hard requirements**: check `llvm-profdata show`
total-count delta on `merged.profdata` against baseline before trusting the
use build (a corpus entry that never starts looks identical to success —
`Item.run` closes the subwindow at its own timeout regardless); two gate
draws minimum before attributing any breach to a real effect.

**Second, separate lever, not yet started**: Mozilla gives each of the ~70
default items 2s and SP3 2 min, vs chromium running each benchmark to its
own completion signal. Jean's "go" also covers raising these to a real
completion signal (talos items already expose `tpRecordTime`) rather than
the fixed 2s — inflates the profile run linearly, own candidate, ships
alongside the corpus widening rather than after.

**MotionMark driving mechanism, resolved**: `MotionMark/resources/runner/motionmark.js`
(the plain `index.html` runner) has NO URL autostart — `startBenchmark` only
fires from a UI click. `MotionMark/resources/debug-runner/debug-runner.js`
DOES: `startBenchmarkImmediatelyIfEncoded()` reads
`Utilities.convertQueryStringToObject(location.search)` and starts the run.
So drive it via `developer.html?<encoded query>`, not `index.html` — avoids
an autostart patch entirely; still needs one `postMessage` completion patch
on the results path.

**Full patch set enumerated** (7 files, applied at build time with the
repo's assert-landed-exactly-once idiom, as `musl-source-fixes.sh` does):
`build/pgo/index.html` (race completion signal vs raised cap, add MotionMark
entry, log per-item elapsed+how-ended), `build/pgo/profileserver.py` (4th
`MozHttpd` on port 8002 for MotionMark), `Speedometer3/resources/main.mjs`
(`postMessage` in `showResultsSummary()`), JetStream3 `JetStreamDriver.js`
(`postMessage` in the `isInBrowser` block), MotionMark runner (same),
`firefox/scripts/apply-and-build.sh:869` (`--extended-corpus` flag),
`playwright/alpine-browsers/Dockerfile` (fetch+unpack both pinned tarballs).

**Bug caught mid-implementation, worth remembering**: the first cut of the
completion-race design used a generic `load` event as one of the signals —
that fires almost immediately for a multi-minute benchmark page (the page
itself loads in ~2s; the benchmark then runs inside it), so it silently cut
SP3/JetStream/MotionMark down to ~2s instead of running them to completion.
Fix: the race must be `message` event carrying the specific
`"corpus-item-done"` payload (or the talos `tpRecordTime` stub turned into a
resolver) vs the raised cap — never a generic page-lifecycle event.

**Status at handoff**: design settled, patch set enumerated, worktree
`perf/ff-pgo-corpus-completion` created off `b8e2248`, Dockerfile + 
`apply-and-build.sh` wiring in progress, the `load`-signal bug just fixed in
the cap model. Nothing committed, nothing dispatched yet.

**Status 2026-09-26**: d3156a6 landed the whole set (7 files, +780: pgo-corpus-patches.py 13 exact-once anchors exit 9, fetch-pgo-corpus.sh, versions.env pins, tests/firefox/test-pgo-corpus-patches.sh wired in tests-firefox.yml). MotionMark went the `?autostart=true` patch route in the end, not developer.html. Pushed + dispatched on jean's go.

**How to apply:** before dispatching, re-verify the JetStream3 tarball sha
is still current upstream and that `--extended-corpus` still exists in this
FF revision's `profileserver.py` (Mozilla renames these). Gate the go/no-go
on the same two-draw discipline that closed #307 — a single draw's breach
row is not stable (see that memory's "reading draw 2 alone invites a wrong
story").

**Profile result (36200910824, c64d783, profile job done 09-26 03:30Z):** merged.profdata Total count **115.74G vs 60.94G (1.90x)**, 405,142 functions, max function count 732.7M. Read by pulling `ff-pgo-profile-sha-c64d783…` and running Alpine llvm23's llvm-profdata in docker (host llvm-20 rejects the format). Profile step exited 0, so the 13 anchors held. Item endings seen: 35 tp, 34 load, Speedometer3 postMessage at 95 s, in-tree Speedometer (no signal) and webaudio hit the 300 s timeout backstop. GOTCHA: JetStream's console.log spam hit buildkit's 2 MiB step-log cap ("[output clipped, log limit 2MiB reached]") mid-JetStream, so JetStream/MotionMark item lines are lost — fix idea (not done): write item lines to /work/pgo/items.log (lands in the pgo-profile image) or raise BUILDKIT_STEP_LOG_MAX_SIZE.
**Gate draw 1 (EPYC 9V74, 09-26 07:32Z): BREACH.** vs official geo 0.823, eval_rtt 1.075 ❌ (cv cand 0.074). vs promoted (ratchet) geo 1.013 — NOT faster despite 1.90x counts; layout 1.050 ❌, screenshot 1.125 ❌ (cv ref 0.073), launch 0.956, eval_rtt 0.986. Conformance green (40/40). One draw only; second draw not dispatched (needs jean's go).

Counted second opinion (09-26 11:07Z): browser-perf-record.yml got a candidate mode (9456ac3: candidate_tag/promoted_tag/rev, staged like perf-gate, report arms via PERF_RECORD_ARMS). Run 36237865129 prices sha-c64d783 vs ff-latest on layout_reflow, screenshot_png_text, js_alloc (control, gate 1.000). Read CPU-ms/iter (cpu-clock, no PMU needed) and instructions/iter (only if the runner has a PMU) per kernel; check the output tags match between arms.

**Counted result (run 36237865129, success 11:30Z, no PMU → CPU-ms only):** same output tags both arms. layout_reflow 1.00x (330.1 vs 329.6 CPU-ms/iter) → gate's layout 1.050 was noise. js_alloc 1.00x control. screenshot_png_text **1.12x CPU / 1.15x wall** (24.0 vs 21.5), delta all in libxul.so (+2.31 ms/iter, 14.08 vs 11.76) → the screenshot breach is REAL, the extended-corpus PGO regresses libxul's screenshot path.

**No PMU anywhere on the hosted fleet (09-26 12:40-13:00Z):** 3b327cf added `playwright/bench/pmu-check.py` (perf_event_open on instructions, candidate mode fails fast without it). Run 36242651767, 8 attempts: EPYC 9V74, EPYC 7763 x4, Xeon 8370C, 8573C, 6973P-C, all ENOENT. The old "an EPYC has one" claim was false (ad44c95 corrected the comment). Past instruction counts came from jean's box (i5-8350U, PMU works, but perf_event_paranoid=4 needs sudo to lower). jean chose option 3: CI check made warn-only (CPU-ms in CI), counts via `playwright/bench/local-counted-compare.sh <firefox|webkit> <candidate_tag> <rev>` on jean's box after `sudo sysctl kernel.perf_event_paranoid=1`.

**Local counted run (jean's box i5-8350U, PMU on, 09-26 ~16:25Z, tmp/counted-sha-c64d.../report.md):** candidate/promoted per iter — screenshot_png_text instr 1.15x at IPC 1.00 (CPU 1.13x), libxul +17.9 M instr/iter; layout_reflow instr 0.96x but IPC 0.91 (iTLB/MI 1.14x) → CPU 1.06x, a layout-of-code cost, not more work; js_alloc control instr 1.10x / CPU 1.04x (JIT, not flat locally — weaker control than in CI).
**Screenshot root cause, disassembled:** libpng's Sub row filter (`movb $0x1` filter byte, bpp copy, then `dst[i]=row[i]-row[i-bpp]`). Promoted libxul 0x3c08690: 32 B/iter `psubb` vector loop. Candidate libxul 0x3fbceef: byte-at-a-time scalar only, no vector path anywhere (awk over the whole disasm found no psubb after a `movb $0x1`), 13%+ of all screenshot instructions on two addresses. Reading (hypothesis, not verified): the extended corpus's 1.90x total counts raised the hot/cold cutoffs, PNG encode fell to cold, clang built it for size. Lever candidates: a screenshot/PNG workload in the corpus, or `-mllvm -pgo-cold-func-opt=default` so cold stays -O2.

**Mechanism CONFIRMED from the profiles (09-27):** it is PGSO, not a cold-function attribute. Both profiles give libpng's filter (MOZ_PNG_write_find_filter) the same max block count, 362,832 (only 420 PNG rows in the whole corpus). The 95% cutoff (`pgso-cutoff-instr-prof` = 950000, SizeOpts.cpp) is 232,664 in 56d0a9c and 446,455 in c64d783. Below it, `shouldOptimizeForSize` → LoopVectorize passes `AllowRuntimeSCEVChecks=!OptForSize` → the Sub filter's alias check is refused → scalar. `-mllvm -pgo-cold-func-opt=default` is a NO-OP: it is clang's default (BackendUtil.cpp:115) and PGOForceFunctionAttrs returns early on it. The lever is `-mllvm -pgso=false`. Method: `llvm-profdata show --detailed-summary` gives the cutoff table; `--all-functions --counts` plus awk gives the per-function max block count.
**Two candidates dispatched 09-27 ~16:08Z, both off c64d783, each compared to c64d783:**
- A `perf/ff-pgo-corpus-png` 052966e, run 36332066698 (full generate+use): the patcher writes `build/pgo/png-encode.html` (twenty 1280x720 text-canvas toDataURL encodes, 695 ms uninstrumented), an item after webaudio. Check its profile: the filter's max block should be ≫446k.
- B `perf/ff-pgo-pgso-off` 7c4e2ab, run 36332109134: `-mllvm -pgso=false` in the PGO use CFLAGS/CXXFLAGS, plus the new dispatch input `ff_pgo_profile_sha` (skips generate, reuses `:ff-pgo-profile-sha-<sha>`). Dispatched with c64d783's profile, so it is the same profile with one flag.
Readout per candidate: the perf-gate vs promoted, then `local-counted-compare.sh firefox sha-<sha> <rev>` for instructions/IPC, then disassemble the Sub filter (psubb back?).
**jean 09-27: "A then B"** → B′ `perf/ff-pgo-png-pgso-off` 41d12dd = A + cherry-picked pgso commit, to be dispatched on A's profile (`ff_pgo_profile_sha=052966e…`). The chain reads c64d783 → A (PNG item) → B′ (pgso, same profile). The background waiter `tmp/wait-a-then-bprime.sh` (log `tmp/wait-a-then-bprime.log`, `=== DONE` marker) dispatches B′ when A's profile job succeeds. The old parallel B (36332109134, pgso on c64d783) is left running as a side reading.
**09-27 19:34Z:** A's profile is green. Filter max block **74.0M** vs cutoff 432,143 (171x over; c64d783 was 362,832 vs 446,455). Total 114.4G. B′ dispatched as run 36344837660.
**GOTCHA, fixed on both pgso branches (11af1da, 7605f90):** a dispatch with `ff_pgo_profile_sha` skips the profile job, and `smoke-firefox`/`smoke-firefox-library` had no `if`. The implicit success() reads ALL upstream jobs, so smoke, conformance and perf-gate all SKIP (old B 36332109134: build green, nothing after). Runs 36332109134 and 36344837660 predate the fix. Workaround: the standalone `perf-gate.yml` with `candidate_tag=sha-<full>`, `promoted_tag=sha-<previous>`, rev 1538 (PW 1.62.1). `tmp/wait-gates-a-bprime.sh` dispatches A vs c64d783, then B′ vs A.

**GOTCHA, candidate B tested nothing (09-27):** the FF producer build is ThinLTO (`--enable-lto=cross`, `MOZ_LTO_CFLAGS=-flto=thin`), so the LoopVectorizer runs in lld's post-link backend, not in the compile step. `-mllvm -pgso=false` went into CFLAGS/CXXFLAGS only, never into the link command. Old B's libxul (sha-7c4e2ab) vs c64d783 has identical byte-SIMD counts (psubb 409, paddb 757 in both), is only +2.8 KB larger, and has no psubb within 60 lines of the Sub filter's `movb $0x1` (promoted 56d0a9c has one at 3c086a4). B′ (41d12dd) has the same flaw. Fix: add `LDFLAGS="$LDFLAGS -Wl,-mllvm,-pgso=false"` in the `use)` block. Gate 36345837925 (B vs c64d783, geo 0.76 vs 0.75) measured a no-op.
Fixed 09-27 21:30Z: 625faad (perf/ff-pgo-pgso-off), 3740e76 (perf/ff-pgo-png-pgso-off) add the LDFLAGS line. B′ redispatched on A's profile: run 36352095178. Old B′ 36344837660 (41d12dd) is flawed, same no-op. Waiter now gates 3740e76 vs A.
