---
name: project_ff_cold_build_ships_unpackaged_tree
description: apply-and-build.sh treats a FAILED `mach build package` as recoverable and falls back to obj/dist/bin, shipping an 8730-file unpackaged tree (xpcshell and all) labelled "artifact OK" — it broke every conformance shard and looked exactly like an LTO regression
metadata:
  type: project
---

Run 33063836129 (`build-firefox` **succeeded**, all 20 `conformance-firefox`
shards died) surfaced this. The shards failed building the conformance RUNNER,
not on tests:

    strip-bundled-libs: removed 73 bundled libs from firefox (firefox)
    ERROR: xpcshell has 1 unresolved deps after strip:
    Error relocating .../xpcshell: XRE_GetBootstrap: symbol not found

**It reads as an LTO regression and is not one.** Two hypotheses were on the
table — LTO internalized the symbol (`--enable-lto=cross` doing cross-TU
internalization), or the strip script removed something. `nm -D` on the two
shipped `libxul.so` settles it in seconds and refutes both:

| | non-LTO baseline | LTO arm |
|---|---|---|
| `XRE_GetBootstrap` | `T XRE_GetBootstrap@@libxul.so` | **`T XRE_GetBootstrap@@libxul.so`** |
| total dynamic symbols (control) | 3043 | 3051 |

Identical export, same version tag, same binding. The symbol was never missing.

**The real cause: `./mach build package` FAILED and the script shipped the
fallback.** From the build log:

    ===== END ./mach build package (rc=2) =====
    ===== DIST resolution: DIST='obj/dist/bin' =====
    ===== Built: .../obj/dist/bin (mach rc=0, package rc=2; artifact OK) =====

`packager.mk:159 make-sourcestamp-file` died on
`mozbuild.preprocessor.Preprocessor.Error: ('../../source-repo.h', None, 'no
preprocessor directives found')` — an EMPTY `source-repo.h`, i.e. missing VCS
metadata. It failed 1.5 s into packaging, in a Python preprocessor that reads a
header. **No codegen flag can reach that**, which is the second independent
proof LTO is innocent.

`$DIST` then fell through to `obj/dist/bin`, the packaging-free build output:

| artifact | entries | shape |
|---|---|---|
| baseline (packaged) | **138** | `application.ini`, `browser/chrome/icons/…` |
| LTO arm (fallback) | **8730** | `.lldbinit`, `.mkdir.done`, `actors/*.sys.mjs`, **`xpcshell`** |

`xpcshell` is a TEST binary that only exists in `dist/bin`. The baseline
artifact does not contain one at all, which is why its strip gate never
examined it. So the gate was right and the artifact was wrong.

**The defect is the fallback's silence.** `pkg_rc=2` is printed and then
overridden by the words "artifact OK" on the same line, and nothing fails. A
build that cannot package should not publish a tree 63x the size of the real
one under the same tag.

**How to apply:**
- Reach for `nm -D` on both artifacts BEFORE theorising about a missing symbol;
  it costs seconds and it refuted two plausible hypotheses at once.
- Compare artifact FILE COUNTS between a new arm and the shipped baseline —
  138 vs 8730 was the tell, and it is cheaper than any symbol analysis.
- This is cold-path-only: the iter path reuses a prebuilt base and never
  re-packages, so it hid the bug for as long as no cold firefox build ran.
  Any future cold build hits it. [[project_ff_prebuilt_base_pin_only_tag_staleness]],
  [[feedback_benign_loud_vs_fatal_log]], [[feedback_verify_moving_tag_payload]]
