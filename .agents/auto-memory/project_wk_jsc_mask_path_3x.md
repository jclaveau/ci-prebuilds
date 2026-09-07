---
name: project_wk_jsc_mask_path_3x
description: on the folded mask path — no libc involved on either side — our WebKit ran the modulo loop 3x slower than Playwright's, 175 ms vs 59, on builds the probe reports as the same 26.5
metadata:
  type: project
---

With the vacuous 2^32 divisor, both arms run JSC's own masked-modulo path and no libc `fmod` is entered (counted: 0 calls, run 34048835048). Ours still took **175 ms against Playwright's 59** — 3x — and 180 vs 68 (2.65x) once the divisor was fixed — on builds the probe labels identically as `26.5`.

**Why it matters:** this is not a musl-vs-glibc gap and not an fmod gap. It is our WebKit build executing JIT-emitted integer-ish arithmetic 3x slower than PW's build of the same version, which contradicts [[project_wk_jit_kernels_are_at_the_floor]] ("a JIT-only kernel runs code JSC emits at RUNTIME, so it is the same code on both sides by construction"). One of the two readings is wrong and the difference is worth its own dig.

**How to apply:** re-measure it deliberately with a kernel that stays on the mask path, confirm the two builds really are the same WebKit revision (the probe's version string is a hardcoded constant — [[project_webkit_version_assertions]]), then look at JIT tier entry (`int_math` reads 1.00, so it is not JIT being off wholesale).
