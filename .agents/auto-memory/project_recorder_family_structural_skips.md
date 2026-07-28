---
name: recorder-family-chromium-bundle
description: FF+WK conformance recorder-UI tests recovered via multi-stage self-contained musl-chromium bundle at /opt/chromium-bundle; the build gotchas
metadata:
  type: project
---

PW's recorder-UI subsystem (`inspector/*`, `slowmo`, `debug-controller`, `selector-generator`, `locator-generator`'s `_enableRecorder` block) INTERNALLY launches a headed **chromium** as its UI harness — distinct from the browser under test. So FF+WK conformance runners (alpine:edge, no chromium) failed all of those with "No chromium-based browser found."

**Fix (IMPLEMENTED 2026-07-16, commits 8b55edf → dd8b583):** multi-stage Dockerfile in `conformance/build-runner.sh` (FF + WK branches). `FROM alpine:3.22 AS chromium-fetch` → `apk add chromium chromium-swiftshader` (chromium 142), gather runtime `.so` deps via recursive `ldd`, `patchelf --set-rpath '$ORIGIN'`, ship the self-contained tree in `/opt/chromium-bundle/`. COPY-from into the alpine:edge FF/WK runner — isolated from the runner's :edge system libs via `$ORIGIN` RPATH (chromium keeps its own :3.22 libFLAC.so.12 etc.; FF/WK binaries keep :edge SONAMEs). Placed at BOTH PW auto-discovery paths: `chromium-${CHR_REV}/chrome-linux64/chrome` AND `chromium_headless_shell-${CHS_REV}/chrome-headless-shell-linux64/chrome-headless-shell` (symlink → chrome), revs read from playwright-core `browsers.json`.

**Three gotchas that each cost a red iter:**
- **dlopen'd libs are invisible to ldd** — chromium NSS init `dlopen`s `libsoftokn3.so`/`libfreebl3.so`/`libnssckbi.so`/`libsqlite3.so.0`/`libplc4.so`/`libplds4.so` at runtime. The recursive-ldd walk misses them → `NSS error code -8023` FATAL. Must copy them explicitly + also `apk add nss` on the runner (SECMOD search-path).
- **crashpad/sandbox helper bins** — `chrome_crashpad_handler` (spawned via `posix_spawn` at recorder launch) + `chrome-sandbox` aren't `.so`; the original `.pak`/`.so`-only copy missed them → SIGTRAP. Blanket `cp -aL /usr/lib/chromium/*` + rename `chromium`→`chrome`.
- **file set differs per alpine tag** — `xdg-mime`/`xdg-settings` exist in :3.22's chromium apk but NOT :3.23's. A `for bin in ...; do [ -f "$bin" ] && for ...; done` loop with no `|| true` returns non-zero on the absent last iteration → aborts the whole `&&` RUN chain. Drop the useless xdg-* + guard `[ -f "$bin" ] || continue`.

**Result:** FF 85.5%→91.5%, WK 88.5%→89.8% of Ubuntu, zero Alpine-only fails.

**Rejected alt:** `apk add chromium@v322` (repo-tag on :edge base) works but auto-downgrades flac 1.4 → risks the FF binary; the multi-stage $ORIGIN-isolated bundle is cleaner (no shared system-lib downgrade).

Related: [[pw-conformance-scope-out-of-scope]] (trace-viewer/codegen the bundle does NOT need to serve), [[webkit-gtk-headed-recursion]], [[pw-conformance-visibility-cluster]].
