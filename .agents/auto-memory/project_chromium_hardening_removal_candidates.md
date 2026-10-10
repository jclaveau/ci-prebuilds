---
name: project_chromium_hardening_removal_candidates
description: PRICED+COUNTED 2026-09-28 — libcxx-fast and cfi-icall-off both at instruction parity with chs-latest (goto_cold 1.00x/0.99x on re-run; the earlier 0.83 was a disturbed run), no speed in #259; once chromium reaches parity with official, the next campaign is stripping security hardening a headless PW test container gets no benefit from (not a perf-lever hunt) — issue #259 ranks 7 candidates; 2026-09-24 jean overrode "one at a time" to "attack them all in parallel", cfi-icall-off/libcxx-FAST/init_stack_vars-off DISPATCHED as parallel branches (runs 35969225761/35969209912/35969241368), BRP-off/libcxx-NONE/SSP-off/fortify-off/ubsan-off PARKED into the *-for-testing family (below official), sandbox/site-isolation explicitly out of scope
metadata:
  type: project
---

**Strategic pivot (2026-09-17), user-initiated:** "we first need to match
parity with equivalent tuning but, once done an investigation to make it
even faster would be very nice, this kind of security which are useless in
a test env are really good candidates for it". Distinct from the
parity-chasing campaign in [[project_chromium_residual_gap_candidates]] —
this is deliberately going *below* official's numbers by removing
hardening whose threat model (untrusted web content, real users) does not
apply to a CI container running Playwright's own test suite behind no
network boundary that matters.

**Filed as issue #259**, "Beyond parity: drop the hardening a test
container does not need". Seven ranked candidates, each a separate A/B
against the parity build (not bundled — a regression in one must not hide
behind a win in another):

1. **`use_cfi_icall=false`** (keep `is_cfi`/`cfi-vcall` ON, drop
   `cfi-icall` only) — the PGO hash lives in
   vcall (310/312 mismatches fixed by vcall alone,
   [[project_chromium_pgo_hash_needs_cfi]]); icall buys zero layout and
   costs jump-table thunks + checks on every indirect call, was also the
   source of the sqlite `ioctl`-cast SIGILL this campaign had to fix.
   Cheapest, most confidently-scoped candidate. **DISPATCHED 2026-09-24**,
   branch `perf/chromium-cfi-icall-off` (a458fd3), run 35969225761, cold
   off `origin/main` d2f0ff9.
2. BackupRefPtr off. **PARKED 2026-09-24** into the `*-for-testing`
   image family, [[parked_for_testing_image_family]] — it goes below
   official (upstream default is ON for linux x64 official) and removes
   the UAF mitigation, so it ships only under a tag that says so.
3. libc++ hardening EXTENSIVE → FAST or NONE (`enable_safe_libcxx`) — same
   lever the Thorium audit ranked #1 for pure codegen speed,
   [[project_chromium_thorium_audit]]. FAST half is a normal parity
   candidate, **DISPATCHED 2026-09-24**, branch `perf/chromium-libcxx-fast`
   (a411aa9), run 35969209912, cold off `origin/main` d2f0ff9 (guarded sed
   with a `grep -c == 1` assertion on the define site,
   `build/config/compiler/BUILD.gn`). NONE half is below official —
   **PARKED**, same family.
4. Stack-protector (SSP) off. **PARKED**, same family — below official.
5. `_FORTIFY_SOURCE` off. **PARKED**, same family — below official.
6. `init_stack_vars` off. **DISPATCHED 2026-09-24**, branch
   `perf/chromium-init-stack-vars-off` (4496915), run 35969241368, cold off
   `origin/main` d2f0ff9.
7. UBSan `array-bounds`/`return` traps off (Chromium's own, not Alpine's
   driver-forced ones). **PARKED**, same family — below official.

**How to apply:** queue only after the parity campaign's chosen build
(currently the CFI candidate, [[project_chromium_pgo_hash_needs_cfi]]) is
the shipped base and read against official directly — wins here are only
meaningful measured against THAT baseline, not against an intermediate.
**Superseded 2026-09-24:** the "one at a time, not fanned out" rule below
held until jean explicitly overrode it — "attack them all in parallel in a
loop" — after the BRP-off classifier denial forced a from-official-security
look at each candidate anyway. Each candidate still isolates exactly one
variable, now via its own branch rather than via sequencing, so attribution
survives the fan-out; four ran as parallel cold chains (three above +
`-march=x86-64-v3`, tracked separately in
[[project_chromium_residual_gap_candidates]]'s 2026-09-24 entry), free on
this public repo. ~~Each candidate is a full ~38h chain; run them one at a
time per #249's established pattern, not fanned out, since a security
regression needs to be attributable to exactly one flag.~~ FF/WK get the
same treatment only if a lever here proves out on chromium first.
Candidates that read below official rather than toward it now have a home:
[[parked_for_testing_image_family]]. Sandbox and site-isolation are
explicitly NOT candidates — those protect the test *process*, not the web
content being tested, and removing them changes behavior PW tests may
depend on.

**Priced 2026-09-28 (perf-gate, 5 shots, vs `chs-latest` = ratchet):**
libcxx-fast a411aa9 (run 36409795747, 8573C) ratchet geo 1.014, WORSE on
goto_cold 1.087 / eval_rtt 1.062 / layout 1.044; cfi-icall-off a458fd3 (run
36409799506, EPYC 7763) ratchet geo 1.003, a tie (parity vs official 1.000).
Neither buys anything measurable over the shipped build: do not ship either
as a perf lever; the remaining #259 rungs are hardening-only, not speed.

**Counted 2026-09-28 (local-counted-compare.sh, i5-8350U, insn/iter vs
`chs-latest`):** libcxx-fast 0.97-1.01 on all 4 kernels — DEAD, its gate
breach was runner noise. cfi-icall-off goto_cold **0.83** (293 vs 353 M,
cycles 0.88), outside chs-latest's own run-to-run spread (353/358); eval
0.91 / warm 0.93 / reflow 1.03 sit inside that spread (±6-10%, counting is
system-wide `-a`, the box was disturbed: wall/task-clock unusable). jean
2026-09-28: re-run cfi-icall-off goto_cold tonight on an idle box
(`PERF_KERNELS=goto_cold`, ×3, candidate/promoted interleave).
**Re-run 2026-09-28 14:03-14:27Z (tmp/counted-cfi-cold-{1,2,3}):** insn/iter
357 vs 356 (1.00x), 352 vs 160 (run 2 promoted pass broken: its stat window
disagrees with the record window, void), 351 vs 355 (0.99x); cycles 1.00x.
The 0.83 was a disturbed run. cfi-icall-off does the SAME work as chs-latest:
DEAD as a speed lever, like libcxx-fast. #259 buys no speed.
**Quiet re-run of the other 3 kernels 2026-10-05 22:57-23:20Z (load 0.7-1.7,
`tmp/counted-night-cfi-icall-off/`):** insn/iter eval_rtt 702 vs 702 (1.00x),
goto_warm 210 vs 214 (0.98x), layout_reflow 1.17e3 vs 1.23e3 (0.95x, but wall
0.99x / CPU 1.00x); wall 0.99x on all three. DEAD confirmed, nothing to re-run.
