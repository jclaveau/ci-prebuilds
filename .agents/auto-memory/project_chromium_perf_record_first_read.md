---
name: project_chromium_perf_record_first_read
description: the first perf profile of chromium (run 33070887464) — screenshot is 100% PNG encode, deflate is at PARITY, and 66% of the overrun is one Skia raster-pipeline float family we enter 6.3x more often; layout is diffuse codegen at +16% instructions / -13% IPC; Alpine's default stack protector is a real artifact-level difference worth +12.0% instructions on a call-dense shape
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

**screenshot is entirely PNG ENCODE — and it is NOT deflate.** Run
**33070887464**, one GHA runner, chromium 151.0.7922.34 both sides, CPU-ms per
iteration (wall is useless on three of these — see the cadence trap below):

| kernel | alpine | official | | |
|---|---|---|---|---|
| `screenshot_jpeg` | 22.2 | 23.4 | **0.95x** | we are FASTER |
| `screenshot_png` (canvas, identical bytes) | 34.8 | 27.2 | **1.28x** | wall 1.00x |
| `screenshot_png_text` (the campaign's page) | 63.2 | 46.4 | **1.36x** | wall 1.31x |
| `layout_boxonly` | 396.1 | 304.7 | **1.30x** | wall 1.34x |

The JPEG control is the same compositing, the same readback, the same pixel
count and the same transport, so **capture and readback are exonerated** — the
opposite of firefox ([[project_ff_png_encoder_gap]]).

**The text kernel carries a confound the canvas control bounds.** Our PNG comes
out 83 728 B against official's 75 095 B: the distros antialias differently, so
our bitmap has more entropy and there is genuinely more to encode. Part of that
1.36x is extra input, not slower code. The canvas control, whose bytes are
**identical on both arms**, is the clean number: **1.28x**.

**`libz.so.1` never appears in the profile at all, and deflate is at PARITY.**
Bucketing the canvas-PNG samples by 64 KiB, the deflate region is 15.71% of our
CPU (5.47 ms/iter) against 19.31% of official's (5.25 ms) = **1.04x**. So
deflate is not the screenshot gap in any form, and the standing reading of the
zlib-ng preload's 4.7 ms as "22% of the overrun with more deflate behind it" is
retired.

**Two thirds of the overrun is one family of Skia raster-pipeline float
stages.** Same bucketing: ours **18.24%** (6.35 ms/iter) against official's
**3.72%** (1.01 ms) = **6.3x, +5.34 ms** — which is **66% of the +8.04 ms
main-binary delta**. Absent from the JPEG profile entirely.

Both binaries contain the SAME function — matched by a 40-byte run of its
instruction bytes with no rip-relative operand in it, ours at `0x535b900`,
official's at `0x5cf8440`. It is reached through a dense run of consecutive
`R_X86_64_RELATIVE` slots (a stage dispatch table) and has **zero direct `call`
sites**, which is what a raster-pipeline stage looks like. It unpacks **10-bit
channels** (mask `0x3ff` at bits 0/10/20), converts int→float with the
`0x4b000000`/`0x53000000` magics, and ends on a real `vdivps` by `510.0f`.

So the two builds run the same code at a similar speed and **differ in how much
of the float pipeline they enter at all** — a fast-path or surface-format
question, not a codegen one. **That is the open end.** Not the display: both
arms report `colorDepth` 24, `dynamic-range: high` false and no wide gamut, and
`--force-color-profile=srgb`, `--disable-gpu`, `--disable-gpu-compositing` and
`--use-gl=swiftshader` all left it unmoved. If it is a difference it is a
build-config one, and the knob is not found yet.

**layout is diffuse codegen, and musl is a twentieth of it.** Per iteration the
main binary is **+80.9 ms** and musl-vs-glibc is **+8.4 ms net** (15.65 against
7.28). No single hot cluster on either side: bucketing spreads the samples over
a dozen Blink regions. On jean's box, where the PMU works, `perf stat` gave the
split directly: **+16% instructions at −13% IPC**. (An earlier read put musl at
19% of the layout gap; that was a single dispatch on a different runner —
[[project_runtime_perf_probe]]'s point that the alpine/official ratio is
runner-CPU-dependent applies here too, so pair by hardware before differencing.)

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

**Priced at +12.0% INSTRUCTIONS on a call-dense shape**, which took three
tries to measure honestly:

1. Timed, on a vector body: 1.868 / 1.864 / 1.782 ms with the flag against
   1.741 / 1.747 / 1.741 without. A 2-7% effect from an instrument whose own
   spread is ±5% — **inside its own resolution, so not a measurement at all**
   ([[feedback_match_instrument_to_effect_size]]). It also had the wrong shape:
   one heavy vector body per prologue understates a per-call cost.
2. Counted, call-dense, but too small: the walk finished in 0.078 ms, so
   `perf stat` was counting process startup. Two reps of the SAME binary read
   573 801 and 551 210 instructions — a 4% spread on an 8% claim.
3. Counted, call-dense, scaled until the workload dwarfed startup (20 000
   rounds, ~1.2 s):

   | | instructions retired | |
   |---|---|---|
   | ssp on | 3 818 502 482 / 3 819 080 138 | spread **0.015%** |
   | ssp off | 3 407 973 208 / 3 410 399 275 | spread **0.07%** |
   | | **+12.0%** | 170x the instrument's resolution |

   Same checksum both arms, canary refs 6 vs 0, so the lever provably varied
   and the work was identical. Wall was +4.7%.

**And it lands on the HOT path, not on cold code.** Per 64 KiB of the top five
layout regions in each binary (comparable instruction counts, 15.6-19.5 k):

| region rank | ours | official |
|---|---|---|
| 1-5 protected functions | 14 / 38 / 62 / 19 / 81 = **214** | 2 / 2 / 2 / 3 / 10 = **19** |

11.3x, matching the binary-wide 10.8x. So the flag is not confined to code the
layout kernel never runs.

**Read against the browser: our layout runs +16% instructions, and a synthetic
call-dense kernel says the stack protector alone is +12%.** That makes SSP the
leading explanation for the INSTRUCTION half of the layout gap — with the
caveat that the synthetic is more call-dense than real Blink, so +12% is an
upper bound. It says nothing about the −13% IPC half, which is a separate
question. The fix is `-fno-stack-protector` in chromium's cflags, and it costs
a cold r1..r12 (25-30 h) because it lives in the setup layer.

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
