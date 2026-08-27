---
name: project_ff_hardening_arm_unresolved
description: --enable-hardening is already ON via aports and omitting the flag enables it too, so deleting the line is a no-op; the --disable-hardening arm reached configure yet produced a byte-identical .text, so hardening is still unpriced
metadata:
  type: project
---

**`--enable-hardening` is already on.** It is in aports' mozconfig, which we
concatenate. There is nothing to add — the only experiment is the inverse.

**Deleting the enable line is NOT how you disable it.** From
`build/moz.configure/toolchain.configure`, in its own words: *"all flags are
actually added in the default no-flag case; making --enable-hardening the same
as omitting the flag."* So the arm must remove aports' line AND append
`--disable-hardening` (moz.configure refuses both spellings of one option).
Caught before the build; deleting alone would have measured nothing.

For clang-22 / x86_64 / release / no-asan the option is worth:

    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
    -fstack-protector-strong          (cflags AND ldflags)
    -fstack-clash-protection          (cflags AND ldflags)
    -fstrict-flex-arrays=1
    -ftrivial-auto-var-init=pattern   (via MOZ_TRIVIAL_AUTO_VAR_INIT)

**The arm is VOID, hardening is still unpriced.** Branch
`perf/firefox-no-hardening` (`febb599`, off `d86baaa`), A/B run 32897356121 vs
`sha-d86baaa…`: every metric `n.s.`, controls flat. But the two libxul differ
only by BuildID — `.text` is **118846320 bytes on both sides**, so codegen never
changed ([[feedback_verify_ab_varied_the_variable]]). The configure log DOES
echo `--disable-hardening`, so the option was seen and the flags still did not
move.

**Next instrument, do not rebuild blind:** have `apply-and-build.sh` echo
`MOZ_HARDENING_CFLAGS` / `MOZ_TRIVIAL_AUTO_VAR_INIT` out of the generated
`config/autoconf.mk` (or `config.status`), so the next ~4 h build returns an
answer either way ([[feedback_ship_diagnostic_when_fix_is_blind]]). Grepping the
job log for the flags cannot work — mach echoes no compile command lines.

Note this is a security-reducing arm; it stays off main regardless of the
number, until jean rules on the trade.
