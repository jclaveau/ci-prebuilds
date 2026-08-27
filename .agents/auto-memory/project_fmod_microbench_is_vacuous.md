---
name: project_fmod_microbench_is_vacuous
description: libm_fmod 5-7x is musl's fmod (glibc 54 ms vs musl 164 ms, gated) — but gcc 15 inlines fmod on a power-of-two divisor, so two C microbenches "measured" it while never calling libc, and nm -D confirmed a call the hot loop never made
metadata:
  type: project
---

**The answer.** `libm_fmod` is musl's `fmod`, not JSC's lowering of `%`.
Evidence, in the order that settles it:

- Both webkit builds, one host: the probe's kernel 184 ms ours / 70 ms
  official (2.63x), but `(i*1.5) % 1024.25` — the *same* `fmod` call at small
  magnitudes — reads 58 / 54 (1.07). `Math.sqrt` and an int-only `%` are at
  parity, so the JIT is healthy.
- Interposed `fmod` and counted: **30,000,033 calls ours, 30,000,057
  official**. Same 3M per invocation. The engines reach libc equally often.
- Isolated, gated: **glibc 54.0 ms, musl 163.8 ms** per 3M calls (3.2x).
- musl's loop walks the exponent difference one bit per iteration with a
  data-dependent branch (~21 unpredictable branches for these operands). A
  branchless rewrite runs **64.5 ms**, near glibc, and is bit-exact over
  6,200,323 differential comparisons. Filed as issue #126.

**The trap, which cost two wrong answers.** With a compile-time power-of-two
divisor, **gcc 15 expands `fmod` inline** and the timing loop never reaches
libc — while the binary still carries `U fmod@GLIBC_2.38` from an unrelated
call site, so `nm -D` confirms a call the hot path never makes. That produced
a confident "musl fmod is only 1.32x glibc" that briefly shipped into a PR
description. A `volatile` divisor was NOT enough.

What fixes it:
- compile with `-fno-builtin-fmod`;
- gate every run on an `LD_PRELOAD` call counter that must report ~3M calls
  before the timing is allowed to count. Both earlier binaries report `NONE`
  under that gate — visibly not measurements.

Also: do not TIME anything with that interposer — it costs ~65 ns/call and
swamps the effect (both arms read ~340 ms under it). Its **count** is
trustworthy, its clock is not.
[[feedback_prove_the_lever_is_connected]] [[reference_gate_can_pass_vacuously]]
[[feedback_microbench_validate_in_situ]]
