---
name: project_chromium_a1_b1_b2_switches_2026_10_08
description: A1/B1/B2 2026-10-08 — runtime state identical to official (software raster, SwiftShader), raster switches move nothing on famille; screenshot_png/goto_warm already at parity there; C1 font fix shipped b53b9ca
metadata:
  type: project
---

B1 (CDP SystemInfo dump, tmp/chr-state-dump.cjs, famille, 151.0.7922.34): ours and official take
the SAME path — gpu_compositing disabled_software, rasterization disabled_software,
multiple_raster_threads enabled_on, WebGL = ANGLE on SwiftShader Vulkan, 0 driver workarounds,
same thread layout. Only diffs: ANGLE initializationTime 128 vs 34 ms (3.8x, GPU process, once per
launch — untracked lead for launch), webgpu disabled_off vs unavailable_software (build flag).
SystemInfo.getFeatureState rejects every base::Feature name; command line needs --enable-automation.

B2 dead: no backend difference to swap.
A1 (famille i3-4005U, perf-alpine:counted = consumer sha-1a9cf49, pre-textstack, 200 s/kernel):

| kernel | candidate | median ms | CPU-ms/iter | M insn/iter |
|---|---|---|---|---|
| screenshot_png | alpine | 54.76 | 69.0 | 159 |
| | --num-raster-threads=1 | 54.11 (0.99x) | 68.0 (0.99x) | 168 (1.06x) |
| | --enable-gpu-rasterization | 54.72 (1.00x) | 68.7 (1.00x) | 155 (0.98x) |
| | official | 54.75 (1.00x) | 68.2 (0.99x) | 159 (1.00x) |
| goto_warm | alpine | 64.69 | 158.7 | 213 |
| | --num-raster-threads=1 | 66.76 (1.03x) | 162.3 (1.02x) | 216 (1.02x) |
| | --enable-gpu-rasterization | 66.04 (1.02x) | 162.9 (1.03x) | 213 (1.00x) |
| | official | 66.37 (1.03x) | 160.0 (1.01x) | 226 (1.06x) |

Ratios vs alpine. official+rt1 wall only (58.00 / 67.45 ms): count-arms.sh picks perf-real only
for the candidate NAMED `official` — name official-image candidates `official*` and fix the test
before reuse. Switches: no lever. The CDP-trace raster 1.9x share does not show on famille.

C1: layout_text checksum was 3837212 ours vs 3774184 official (FreeSans otf vs ttf); bundled
probe-sans.ttf → 5510192 both; shipped b53b9ca with PERF_BROWSER_ARGS plumbing.
Parked rest: [[parked_chromium_residual_tracks_2026_10_08]].
