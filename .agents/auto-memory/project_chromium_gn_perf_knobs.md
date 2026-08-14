---
name: chromium-gn-perf-knobs
description: What is_official_build actually implies for the musl chromium build — thin LTO and PGO both default ON under it, and the PGO profile is a public download needing no depot_tools
metadata:
  type: project
---

`is_official_build = true` (adopted on main, `f28b6b6`) is not one knob — it
flips defaults our overlay then has to pin back deliberately.

**`use_thin_lto`** — verified in `build/config/compiler/compiler.gni` @148.0.7778.96:

```gn
use_thin_lto = is_cfi || (is_clang && is_official_build && chrome_pgo_phase != 1 &&
                          (is_linux || is_win || ...))
```

`is_cfi=false` and `chrome_pgo_phase=0` do **not** suppress it; `is_clang &&
is_official_build && is_linux` still satisfies the disjunct. So the explicit
`use_thin_lto = false` is load-bearing, and its cost would land in the finalize
job — which runs ninja to completion plus the link with no timeout headroom.

**`chrome_pgo_phase`** — `build/config/compiler/pgo/pgo.gni`:

```gn
chrome_pgo_phase = 0
if (!is_cronet_build && !dcheck_always_on && is_official_build &&
    (... || (is_linux && !is_castos) || ...)) { chrome_pgo_phase = 2 }
```

Our config (official + DCHECKs off + linux) **already defaults to 2** — the
explicit `0` is what keeps PGO off, not missing support.

**PGO needs no depot_tools.** `build/config/compiler/pgo/BUILD.gn` only shells
out to `tools/update_pgo_profiles.py` (which wants gsutil) **when
`pgo_data_path` is empty**. Set it and that path is skipped. The profile is
named by a sha1 in `chrome/build/linux.pgo.txt` and is a plain public object:

```
https://storage.googleapis.com/chromium-optimization-profiles/pgo_profiles/<name>.profdata
→ HTTP 200, ~83 MB, no auth
```

Both are under measurement on `perf/chromium-pgo` and `perf/chromium-thinlto`
(EXPERIMENT commits, not for merge as-is), each branched off the
is_official_build=true main so they measure their own knob.

Related: [[project_chromium_dcheck_from_is_official_build]], [[project_chromium_from_source_split_build]].
