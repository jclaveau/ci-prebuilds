---
name: project_ff_symbol_strip
description: Firefox shipped 51.8 MB of .symtab/.strtab (no DWARF — aports sets --disable-strip, not debug symbols); stripping in bundle-dist.sh is parity with official AND our own WebKit, worth 52 MiB on disk but only 8.4 MiB compressed
metadata:
  type: project
---

Merged `04af46d` (PR #111).

**There is no DWARF in our libxul.** aports' mozconfig already carries
`--disable-debug-symbols` and it works — `readelf -S` shows zero `.debug_*`. An
earlier "34 MB of DWARF" claim was wrong. What it carries is the **symbol
table**, because aports also sets `--disable-strip` (a distro builds symbols
here and strips in `package()`, which we never run — we call `./mach build`):

    .strtab  41.2 MB
    .symtab  10.5 MB   = 51.8 MB of a 380 MB bundle

Mozilla's own libxul in `mcr…:v1.62.1-noble` has **neither** section, and our
WebKit dist is already stripped identically in `webkit/Dockerfile.finalize`.
Firefox was the last unstripped bundle, so this is parity, not a new tradeoff.
Neither section is SHF_ALLOC, so nothing leaves the runtime image.

**Size the claim compressed, not with du** ([[project_strip_must_precede_final_copy]]):

    on disk      380 MB -> 325 MB   (52 MiB, 95 ELFs in the producer)
    compressed   126.4 -> 118.0 MB  (8.4 MiB — the number that matters)

Symbol tables compress well; quoting the 52 is overselling it ~6x.

**Gotchas baked into the pass:**
- Lives at the END of `bundle-dist.sh`, which BOTH the cold and iter entrypoints
  source, so the conformance runner inherits it (tested == shipped).
- ELF-magic gate is load-bearing: `icudt78l.dat` (33 MB) sits in the same dir
  and must never be handed to `strip`.
- `du -sk`, never `du -sb` — the builder is busybox
  ([[feedback_alpine_busybox_gnu_shim_quirks]]).
- `binutils` is now an explicit dep in BOTH `Dockerfile` and
  `Dockerfile.prebuilt-base` ("keep in sync" comment); it was only transitive.
- Validated before the build: `firefox --version` still 153.0 (the Tier-1
  assert), Playwright drives it, screenshot byte-identical at 8511 bytes.
