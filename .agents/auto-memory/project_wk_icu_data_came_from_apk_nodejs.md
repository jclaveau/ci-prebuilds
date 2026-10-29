---
name: project_wk_icu_data_came_from_apk_nodejs
description: alpine WebKit needs /usr/share/icu/78.1/icudt78l.dat (icu-data-en) — bundled libicudata.so.78 is a 9.5 KB stub; it came unlisted via apk nodejs until b510cd8 swapped node, broke every newPage
metadata:
  type: project
---

2026-10-29: b510cd8 (nodejs.org musl tarball replaces apk `nodejs`, #351) dropped `icu-libs` + `icu-data-en` from the base. Alpine WebKit's bundled `libicudata.so.78` is a 9.5 KB stub, so ICU opens `/usr/share/icu/78.1/icudt78l.dat`; missing → every `newPage` dies "Target page, context or browser has been closed" (perf-webkit 3/3). Firefox unaffected (ships its own icudt78l.dat).

Bisect on the promoted sudoer image: apk coreutils back → FAIL; LD_PRELOAD= → FAIL; `apk add icu-data-en` alone → OK. Fix 20bbe00 lists `icu-data-en` in playwright/Dockerfile.alpine runtime-libs.

**Why missed:** test-playwright-usage drops the webkit project on alpine (`PW_WEBKIT_UNSUPPORTED`, #100); only perf-webkit launches alpine WebKit in the main pipeline, and it does not gate promote.

**How to apply:** removing any apk package from a base → diff `apk info` of old vs new image for what it pulled transitively (icu, brotli, c-ares…) before trusting the browser layers. Related [[project_alpine_node_gap_is_apk_build_config]].
