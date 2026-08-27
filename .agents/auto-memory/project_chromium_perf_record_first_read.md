---
name: project_chromium_perf_record_first_read
description: the first perf profile of chromium — screenshot is 100% PNG encode and NOT deflate (libz never appears), the cost is a Skia raster-pipeline float family our build runs 3.4x more of; layout is diffuse codegen; the stack-protector difference is real on the artifact but priced inside its own instrument's spread
metadata:
  type: project
---

Ten static candidates had been eliminated off the two binaries and each cost a
round trip and moved nothing ([[project_chromium_residual_gap_candidates]]).
The profile named a cause on its first run.

**The recipe.** `perf` inside each arm's OWN container, because perf resolves a
sample to a DSO from the kernel's mmap records and those carry the path as the
sampled process sees it — a perf on the host resolves nothing.

- `--privileged` **bypasses `perf_event_paranoid` entirely** (CAP_SYS_ADMIN), so
  jean's box profiles fine at paranoid=4 with no sudo. This retires
  [[reference_jean_no_passwordless_sudo]] as a blocker for perf work.
- `perf record -a -G /` narrows system-wide sampling to the container's own
  cgroup, which under a cgroup namespace is exactly the arm. Without it a box
  running other agents profiles their builds.
- `-e cpu-clock`, not the default `cycles`: hosted runners are VMs whose PMU is
  often not virtualised through. (On jean's box the hardware counters DO work.)
- `perf stat` wants **`-e` BEFORE `-G`** or it dies "must define events before
  cgroups" — and a `|| true` turns that into a silently empty counter block.
- perf runs as root and `perf.data` is 0600, so `upload-artifact` dies EACCES
  *after* every measurement is taken. `sudo chown -R` before the upload step.
- alpine: `apk add perf` (7.1.5). noble: `apt-get install linux-tools-generic`,
  then call `/usr/lib/linux-tools-*/perf` directly — `/usr/bin/perf` is a
  wrapper that refuses on a kernel-version mismatch.

**screenshot is entirely PNG ENCODE — and it is NOT deflate.** GHA runner, run
33068472779, chromium 151.0.7922.34 both sides, identical output digests,
CPU-ms per iteration:

| kernel | alpine | official | |
|---|---|---|---|
| `screenshot_jpeg` | 21.0 | 21.4 | **0.98x — we are faster** |
| `screenshot_png` | 34.9 | 27.7 | 1.26x CPU |
| PNG-specific (png − jpeg) | **13.9** | **6.3** | **2.2x** |

The JPEG control is the same compositing, the same readback, the same pixel
count and the same transport, so **capture and readback are exonerated** — the
opposite of firefox ([[project_ff_png_encoder_gap]]).

**`libz.so.1` does not appear in the profile AT ALL, on either arm.** Deflate is
not where the screenshot goes, which retires the standing reading of the
zlib-ng preload's 4.7 ms as "22% of the overrun, and the rest is more deflate".
Whatever that preload moved, the encode's cost is elsewhere.

**Where it goes: a family of Skia raster-pipeline float stages.** 27.0% of our
whole CPU during a PNG loop, against 7.9% of official's, and **absent from the
JPEG profile entirely** (0 samples). Both binaries contain the SAME function —
matched by a 40-byte run of its instruction bytes with no rip-relative operand
in it, ours at `0x535b900`, official's at `0x5cf8440`. It is reached through a
dense run of consecutive `R_X86_64_RELATIVE` slots (a stage dispatch table) and
has **zero direct `call` sites**, which is what a raster-pipeline stage looks
like. It unpacks **10-bit channels** (mask `0x3ff` at bits 0/10/20 — so a
1010102 surface), converts int→float with the `0x4b000000`/`0x53000000` magics,
and ends on a real `vdivps` by `510.0f`.

So the two builds run the same code at similar speed and **differ in how much
of the float pipeline they run at all** — a fast-path/format question, not a
codegen one. That is the open end.

**layout is diffuse codegen, and musl is a fifth of it.** Same run, 80 s loop:
alpine 225 iterations at 340.5 ms, official 295 at 259.6 = **1.31x**, not
cadence-clipped. Per iteration: main binary +67 ms, and musl 6.44% vs glibc
2.50% = **+17 ms, 3.4x — about 19% of the gap**. No single hot cluster on
either side: bucketing the samples by 64 KiB spreads them over a dozen Blink
regions. On jean's box `perf stat` gave the split directly: **+16%
instructions at −13% IPC**.

**The stack protector is a REAL artifact-level difference, unlike firefox's.**
[[project_ff_hardening_arm_unresolved]] died because Mozilla adds the flags in
the default no-flag case, so official carried the identical set. Not here —
counted on both SHIPPED binaries, not the recipes:

| | ours | official |
|---|---|---|
| `mov %fs:0x28,%r*` canary loads | **358 107** | **33 166** |
| `__stack_chk_fail` imported | yes | yes |

Same chromium version, near-identical binary size, so the function population is
the same and a 10.8x density difference is the flag. Alpine's clang 22 defaults
`-fstack-protector-strong` ON (4 canary refs on a trivial function, 0 with
`-fno-stack-protector`); upstream clang defaults it off, and chromium enables it
for a subset of its own.

**But it is not yet priced.** `ssp-cost-bench.c` on a vector-body shape read
1.868 / 1.864 / 1.782 ms with the flag against 1.741 / 1.747 / 1.741 without —
a 2-7% effect from an instrument whose own spread across repeats is about ±5%.
**A difference inside its instrument's spread is not a measurement**
([[feedback_match_instrument_to_effect_size]]). The right instrument for
"does this flag make us execute more" is **instructions retired**, which is
deterministic between runs; the bench grows a call-dense kernel for exactly
that, since layout is thousands of small out-of-line calls and a prologue is a
much larger fraction of those than of one heavy vector body.

**Two traps that cost real time here:**

- **A shared box contaminates a sequential A/B.** The first alpine PNG run read
  53.6 ms and 1164 iterations; the identical re-run read 35.0 ms and 1776. Two
  other agents were building. The arms must be interleaved and the control
  re-read — the JPEG control passing is NOT enough, it passed in the
  contaminated pass too. [[feedback_check_reference_stability_across_runs]]
- **A frame-quantized kernel cannot explain the metric it was built for.** A
  flat-canvas PNG shot lands ON the ~33 ms compositor cadence on a hosted
  runner for BOTH arms: 1.01x wall while the CPU underneath is 1.26x. Shoot the
  800-row antialiased-text page runtime-probe.cjs actually shoots, and read
  CPU-ms per iteration rather than wall. Same reason `locator_click` is pinned.

**How to apply:** `chromium-gap-probes.yml`, `run_perf_record=true`, any
consumer image tag; ~1 h, builds nothing. It lives there rather than in its own
workflow because **a workflow absent from the default branch cannot be
dispatched at all** — `gh workflow run <new-file> --ref <branch>` is a flat 404,
while an existing workflow dispatched with `--ref <branch>` runs the BRANCH's
version of it. That is the way to iterate on CI-only instruments here.
