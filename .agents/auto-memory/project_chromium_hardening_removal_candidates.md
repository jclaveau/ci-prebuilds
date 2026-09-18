---
name: project_chromium_hardening_removal_candidates
description: once chromium reaches parity with official, the next campaign is stripping security hardening a headless PW test container gets no benefit from (not a perf-lever hunt) — issue #259 ranks 7 candidates (cfi-icall off, BackupRefPtr off, libc++ hardening FAST/NONE, SSP off, fortify off, init_stack_vars off, ubsan array-bounds/return off), each its own A/B against the parity build, gated behind #249, sandbox/site-isolation explicitly out of scope
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
   Cheapest, most confidently-scoped candidate.
2. BackupRefPtr off.
3. libc++ hardening EXTENSIVE → FAST or NONE (`enable_safe_libcxx`) — same
   lever the Thorium audit ranked #1 for pure codegen speed,
   [[project_chromium_thorium_audit]].
4. Stack-protector (SSP) off.
5. `_FORTIFY_SOURCE` off.
6. `init_stack_vars` off.
7. UBSan `array-bounds`/`return` traps off (Chromium's own, not Alpine's
   driver-forced ones).

**How to apply:** queue only after the parity campaign's chosen build
(currently the CFI candidate, [[project_chromium_pgo_hash_needs_cfi]]) is
the shipped base and read against official directly — wins here are only
meaningful measured against THAT baseline, not against an intermediate.
Each candidate is a full ~38h chain; run them one at a time per #249's
established pattern, not fanned out, since a security regression needs to
be attributable to exactly one flag. FF/WK get the same treatment only if
a lever here proves out on chromium first. Sandbox and site-isolation are
explicitly NOT candidates — those protect the test *process*, not the web
content being tested, and removing them changes behavior PW tests may
depend on.
