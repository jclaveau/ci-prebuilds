---
name: chromium_cft_build_chain_diff
description: The official arm IS Chrome for Testing, and the flag-by-flag diff against our chain leaves exactly three live divergences — clang 22 vs pinned LLVM 23, 17 unbundled system libs vs an all-bundled LTO+PGO unit, and musl-vs-Debian-sysroot
metadata:
  type: project
---

The `official` arm every ratio is measured against is **Chrome for Testing's own
binary**, not a Playwright build. PW 1.62.1's `browsers.json` names
`chromium-headless-shell` = "Chrome Headless Shell" at 151.0.7922.34, the same
version our build reports, and PW switched to CfT binaries in 1.57. CfT is built
from the Chrome *release* codebase with only `BUILDFLAG(CHROME_FOR_TESTING)` +
`GOOGLE_CHROME_FOR_TESTING_BRANDING` added — branding, profile dir, component
updates off, proprietary codecs on. **No optimisation flag differs from Chrome
release**, so the reference is a full official Chrome build.

Everything else in official's config is the `is_official_build = true` default
set for linux/x64 — the public `linux-official` builder's `gn-args.json` carries
only `is_official_build`, `target_cpu`, `target_os` and the remote-exec knobs.

Flag-by-flag, ours vs CfT (aports' own values in brackets where we override):

| | CfT | ours | verdict |
|---|---|---|---|
| `is_official_build` | true | true | parity |
| `chrome_pgo_phase` | 2 | 2 [aports 0] | parity — we fetch the SAME profile, named by `chrome/build/linux.pgo.txt` out of `chromium-optimization-profiles` |
| `use_thin_lto` | true | true [aports false] | parity |
| `symbol_level` / `dcheck_always_on` | 0 / false | 0 / false | parity |
| linker | lld | lld [aports mold] | parity |
| `is_cfi` / `use_cfi_icall` | **true** (default on linux-x64 official) | false | diverges in OUR favour — official pays checks we skip |
| stack protector | clang default (level 1) | Alpine driver forces 2, overridden to 1 in CFLAGS | being priced by the SSP chain |
| `use_sysroot` | true (Debian sysroot, glibc) | false (musl) | **unfixable, and the point of the project** |
| toolchain | Chromium's pinned clang, `llvmorg-23-init-19482-g53d18880` | Alpine `clang22` via `unbundle:default` | **live candidate** |
| third_party libs | all bundled, inside the LTO+PGO unit | 17 replaced by system `.so` via `replace_gn_files.py` | **live candidate** |
| codecs / webrtc / dawn / nacl | on | off | smaller binary, not layout-hot |

The library one is the strongest mechanical story for a *diffuse* gap: a system
`.so` is built at Alpine's flags (`-Os` — proven on libpng, see
[[project_wk_screenshot_is_alpine_os_libpng]]), gets neither ThinLTO nor the PGO
profile, and every call into it is a cross-DSO call that cannot inline. Official
compiles all of that source inside one LTO unit with the profile applied.
`perf/chromium-unbundle-libs` already re-bundles 11 of the 17; what it leaves
system is fontconfig (bundled copy uses `initstate_r`/`random_r`, absent in
musl), freetype, harfbuzz, libdrm, openh264 — so the text stack stays outside
the LTO unit even after that chain lands, which is a separate, untested lever
from the font-FILE hypothesis that
[[project_probe_font_mismatch_confounds_layout]] already killed.

**Why:** a 68 ms layout delta with no address above 0.4%
([[project_chromium_layout_is_diffuse_no_hotspot]]) cannot be profiled to a
fix; it has to be a build-wide codegen difference, and this table is the
enumeration of which ones are actually left.

**How to apply:** do not re-open CFI, PGO, ThinLTO, mold-vs-lld or the PGO
profile — they are parity or in our favour. The two remaining are the clang
major and the un-LTO'd system libs, and only the second has a chain in flight.
