---
name: project_ff_numbermod_placement_breach
description: FF libm_fmod ratchet 1.04-1.06 after linking fmodf was js::NumberMod straddling a 64 B line; aligned(64) in a214d8e fixed it (1.002)
metadata:
  type: project
---

Linking libm-fmodf-custom.o into libxul (79f0a79) moved `js::NumberMod`
(47 B, JS `%` → fmod) from 0 to 48 mod 64. fmod and NumberMod bytes were
identical, yet the libm_fmod ratchet breached 3 draws: 1.056 (9V74), 1.041 and
1.045 (7763). a214d8e: `__attribute__((aligned(64)))` on its definition in
`js/src/util/PortableMath.h` (apply-and-build.sh 6b) plus a post-link nm check
→ 9V74 ratchet 1.002, ff-latest promoted (run 38063515297).

Local Haswell copy test at 48 vs 0 mod 64: +0.38% only. Intel underplays what
Zen pays (~1 cycle per call), so a null local Intel result would NOT have
cleared placement.

**Why:** any object added to libxul reshuffles hot tiny functions; the gate
reads it as a regression of code nobody touched.

**How to apply:** when a row moves with byte-identical code, compare the hot
symbols' `addr mod 64` in candidate vs promoted (`docker export` the payload
image — it has no shell — then nm `symbols/libxul.so`) before blaming noise.
Related: [[project_chromium_layout_gap_is_frontend_fetch]].
