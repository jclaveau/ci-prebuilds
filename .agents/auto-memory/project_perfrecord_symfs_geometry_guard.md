---
name: project_perfrecord_symfs_geometry_guard
description: perf-profile.sh's symfs twin-matching (PR #282) compares .text section address+size, not build-id — libs here carry no build-id note at all
metadata:
  type: project
---

`browser-perf-record.yml`'s symfs mechanism (unstripped twin image at
`/symbols`, PR #280) had two bugs found reading the first real wk/ff runs,
fixed in PR #282:

1. **The `official` target was getting OUR twin.** Neither our libs nor
   official's carry an ELF build-id note, so the original match had no real
   guard and `official-*-symbols.md` claimed symbols "named from its
   unstripped twin" when it was actually naming OUR binary's addresses against
   THEIR profile. Fixed with a `.text`-section geometry compare:
   ```sh
   text_geometry() { readelf -S -W "$1" | sed -n 's/^.*\] \.text  *//p' | awk '{print $2, $4}'; }
   ```
   only accepted as a twin if address+size match exactly (verified locally:
   ours `19d0a00/6567409` vs official's `806000/5e0b712` — different, correctly
   rejected now) and the candidate actually has a `.symtab`.
2. **`alpine-launch-symbols.md` came back empty.** `launch` is 46% kernel +
   31% ld-musl + 8% libgcc_s, engine code only ~0.5% of samples — every symbol
   fell under perf report's default 0.2%-of-total floor. Fixed by reporting
   `--percentage relative` (share of the engine's own samples, not of the
   whole profile) with `--percent-limit 0.2` applied to that relative base.

**How to apply:** don't trust a `*-symbols.md` file's own claim of which twin
it used — if debugging a future perf-record run, check for a `.text` geometry
match failure message ("no unstripped twin matching ... — engine samples stay
unnamed") rather than assuming symbolization worked because the file has
content. Firefox still has no twin at all (no equivalent chain built yet
before [[project_ff_pgo_arm_mechanics]]'s libxul-twin PR #284 landed) — check
whether that shipped before assuming ff profiles are still unnamed.
