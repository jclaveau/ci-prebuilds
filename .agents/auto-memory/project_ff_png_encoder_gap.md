---
name: project_ff_png_encoder_gap
description: RESOLVED — musl Firefox's 1.50x-larger PNGs were Alpine's system libpng/zlib; bundling Mozilla's copies makes the canvas control byte- and sha-identical to official
metadata:
  type: project
---

Our musl Firefox screenshots at 0.68x vs `mcr.microsoft.com/playwright:v1.62.1-noble`
(runtime probe, run 32460180480). The whole gap is full-viewport PNG encode.

Measured (`ff-screenshot-diagnosis`, run 32461286072), canvas control, no fonts:

| case | alpine | official |
|---|---|---|
| png_canvas_control | 28.2 ms / 40150 B | 21.5 ms / 26801 B |
| jpeg_q80_canvas_control | 21.0 ms / 41079 B | 18.8 ms / **41079 B, same sha** |
| png_clip_16x16 | 8.8 ms | 8.2 ms |

- Identical JPEG bytes+sha ⇒ **both builds rasterize the same pixels**. The first
  run without this control was confounded: the text page uses distro fonts, and
  different antialiasing alone makes a bitmap bigger AND slower to deflate.
- From that identical bitmap our PNG is 1.50x larger ⇒ a different encoder or
  different deflate settings. **Optimisation flags cannot change output bytes**,
  so PGO/LTO are ruled out for the SIZE (they can still cost time).
- The 16x16 clip is at parity ⇒ capture, readback and transport are fine.

Cause: aports' mozconfig sets `--with-system-png` + `--with-system-zlib` (Alpine
zlib 1.3.2, libpng 1.6.58); Mozilla ships its own copies. `--with-system-jpeg`
already matches the reference byte-for-byte.

Secondary: aports enables PGO inside its APKBUILD `build()`, which we never run —
see the note in `firefox/mozconfig.overlay`. Our FF is LTO-but-not-PGO.

**RESOLVED 2026-08-21** — arm `perf/firefox-bundled-imaging` (build 32462261885,
diagnosis 32481799551) deletes the two mozconfig lines. The canvas control goes
**40150 B → 26801 B with sha 2768ce17d3c727d9, byte-identical to official**, and
its 0.76x timing — the only significant row in the control run — becomes n.s.
The encoder was the whole cause; PGO is not implicated in the size and no longer
needs to be tried for it.

| case | control (system) | arm (bundled) | official |
|---|---|---|---|
| png_canvas_control | 40150 B | **26801 B, same sha** | 26801 B |
| png_viewport | 25018 B | 12188 B | 10875 B |

`png_viewport` cannot reach parity — the page uses distro fonts, so the bitmaps
genuinely differ — but it drops from 2.30x official's size to 1.12x.

Cost: **+122,670 B compressed** (136.5 → 136.6 MiB), and conformance-firefox
stayed 20/20 with conformance-runtime-parity green.

**How to apply:** bundling fights this repo's system-lib/dedup direction, so
whether to land it is the user's call, not a foregone conclusion — the evidence
is in, the decision is not. The measurement recipe generalises: for any
"our output bytes differ" question, use the canvas control (identical JPEG sha
proves the bitmap is shared) and read the byte count, never the timing.
See [[project_ff_build_two_pass_cbindgen]], [[feedback_prove_the_lever_is_connected]].

**2026-08-21 — separated: it was libpng, not zlib.** The one-variable arm
(`perf/firefox-bundled-zlib`, removes only `--with-system-zlib`, keeps
`--with-system-png`, asserted both ways in `apply-and-build.sh`) came back at
`png_canvas_control` = **40150 B** — the untouched system-both number, zero
movement. Official is 26801 B. `jpeg_q80_canvas_control` is 41079 B with the
SAME sha on both sides, so the rasterized pixels are identical and the delta
is purely the PNG encoder. Run 32508149937.

Also the first VERSION-MATCHED firefox comparison we have had: both binaries
report Firefox 153.0. Every earlier one was our 147.0.1 against official's
150.0.2 and mixed three releases of browser change into the ratio
([[project_pw_release_tag_pins_disagree]]).

Open: the full arm bundled BOTH libraries for +122,670 B. A libpng-only arm
would presumably buy the same 13.3 kB saving per canvas shot for less image;
not built, and landing any of it is still jean's call.

**2026-08-22 — RETRACTED: the elimination was wrong.** The libpng-only arm
(`perf/firefox-bundled-libpng`, run 32540949752) also came back at
**40150 B**, sha `9466cb98` — bit-identical to the zlib-only arm and to the
untouched baseline. The full table:

| arm | png_canvas_control |
|---|---|
| baseline (both system) | 40150 B |
| bundled zlib only | 40150 B |
| bundled libpng only | 40150 B |
| **both bundled** | **26801 B** (= official, byte- and sha-identical) |

`jpeg_q80_canvas_control` is 41079 B same-sha on every arm, so the rasterized
pixels were never in question on any of them.

So "by elimination libpng carries all of it" — written here after the zlib arm
— was unsupported. Elimination assumed the two effects were independent, and
this says they are not, OR that the single-library arms never took effect. The
second is the likelier and is NOT yet excluded: the arms' guards proved the
MOZCONFIG OPTION changed, not that the built libxul stopped linking the system
library. `--with-system-png` removed while Mozilla's libpng still pulls system
zlib (or vice versa) could silently fall back.
[[feedback_verify_ab_varied_the_variable]], [[feedback_prove_the_lever_is_connected]]

**Next, before any further conclusion:** `readelf -d libxul.so | grep NEEDED`
on each arm's artifact. A single-library arm whose libxul still NEEDs
`libpng16.so.16` (or `libz.so.1`) did not vary its variable and its 40150 B
means nothing.

**2026-08-22 — RESOLVED. Both arms were valid; it is a real interaction.**
`readelf -d libxul.so | grep NEEDED` on each artifact:

| arm | DT_NEEDED | png_canvas_control |
|---|---|---|
| baseline | `libz.so.1`, `libpng16.so.16` | 40150 B |
| bundled zlib only | `libpng16.so.16` (libz gone ✓) | 40150 B |
| bundled libpng only | `libz.so.1` (libpng16 gone ✓) | 40150 B |
| both bundled | neither | **26801 B** |

**Mozilla's zlib is the cause; bundling libpng is the PRECONDITION for it to
be reachable.** With `--with-system-png` kept, PNG encoding happens inside the
external `libpng16.so.16`, which carries its own linkage to system
`libz.so.1` — so the in-tree zlib is compiled into libxul but never on the PNG
path. That is why zlib-alone changes nothing. And Mozilla's libpng against
system zlib is byte-identical to Alpine's libpng against system zlib, so the
filter choices are not the variable. Only with both in-tree does the path
reach Mozilla's deflate (their tree carries **zlib-rs**, a Rust
reimplementation whose output need not match C zlib).

**So it cannot be shipped by halves.** +122,670 B buys the 13,349 B/shot
saving only as a pair; there is no cheaper libpng-only variant. Landing it is
still jean's call.

**Method note.** "By elimination libpng carries it" was recorded here twice
before being retracted. Two single-variable arms agreeing with the baseline is
NOT evidence that the variables are inert — it is equally consistent with one
of them being unreachable. `DT_NEEDED` on the built artifact is what separated
those, and it cost three wrong conclusions to reach for it.
[[feedback_prove_the_lever_is_connected]],
[[feedback_control_excludes_one_mechanism]]

**2026-08-23 — the number that actually decides it is TIME, not size.** jean:
"more important is fastest tests, not artifacts size". Every earlier reading
here was bytes, because bytes are deterministic and settle attribution; the
timing question needed its own experiment, ours-vs-ours on ONE runner
(`ff-latest` vs the both-bundled arm), not ours-vs-official which confounds
musl, the runner and the build.

Two runs, 32640911593 and 32641010090:

| row | run 1 | run 2 |
|---|---|---|
| `png_viewport` | 0.77x | 0.70x |
| `png_canvas_control` | 0.78x | 0.75x |
| `jpeg_q80_viewport` | 0.97x | **1.21x** |
| `jpeg_q80_clip_16x16` | 1.00x | 0.99x |
| `jpeg_q80_canvas_control` | 1.02x | 1.09x |

**~25% faster PNG screenshots**, and `png_viewport` bytes 25018 -> 12188 (-51%)
on the real page — more than the canvas control's -33%, and the speed comes
WITH the smaller output, not traded against it.

**Read it as two populations, not per-row significance.** Every row is flagged
`n.s.` because the single-row noise floor is ~±20% — run 2's JPEG hit 1.21x on
a row whose bytes and sha are IDENTICAL between the images, which is pure
noise. But PNG never landed near 1.0 in 4 measurements while JPEG never landed
near 0.75 in 6. The populations do not overlap. Arguing "the control is flat
therefore PNG is real" off run 1 alone was luck; the repeat is what made it a
claim. [[feedback_size_verification_to_failure_rate]],
[[feedback_check_reference_stability_across_runs]]

**Still unmeasured:** suite-level impact = 25% x screenshot frequency. Needs
the bundled build published under a real tag so `benchmark-playwright.yml`
benches it end-to-end like the others.

