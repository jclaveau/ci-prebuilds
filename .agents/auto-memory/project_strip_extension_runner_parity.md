# Consumer strip extension: runner parity + libvpx exception

2026-08-11, landed as `248f01c` (main, after PR #93). Extended the
consumer-side dedup (`strip-bundled-libs.sh`) from "universal runtime libs
only" to **every lib with an apk twin**:

- **Firefox** (73 libs): +NSS/nspr (`libnspr4`/`libnss3`/`libnssutil3`/`libplc4`/`libplds4`/`libssl3`/`libsmime3`) + `libglycin` codec
- **WebKit** (78 libs): +`libaom`/`libdav1d`/`libjxl`(+`libjxl_cms`)/`libyuv` codecs + WPE core (`libwpe-1.0`/`libWPEBackend-fdo-1.0`) + `libcrypto.so.3` + `libgstwebrtc-1.0`
- Sizes: ff 342→306M, wk 760→483M (+ Mesa closure strip's ~225M)

**Runner parity is load-bearing**: the conformance runner (`build-runner.sh`)
applies the SAME strip + apk-parity package sets, so **tested layout == shipped
layout**. Validated: FF + WK edge conformance both 21/21 green (`31397868374` /
`31397875788`). Never strip a lib the edge runner can't validate.

**libvpx stays bundled BY EXCEPTION** — the sole lib where shipped ≠ runner
layout. Firefox's `libxul` needs the mozilla-built vpx symbol set; alpine:edge's
`libvpx` apk doesn't export it (22 unresolved vpx_* symbols at `firefox
--version`), while alpine 3.24's does. Since conformance runs on edge, a
vpx-stripped layout is un-validatable → keep it bundled (~7M stays duplicated).
Rationale documented in the strip script header — do NOT re-enable blindly.

Runner apk additions (FF/WK) mirror the edge closure test containers exactly
(`ffr-closure`/`wkr-closure`); edge pkg names diverge from 3.24 (`libsoup3`
not libsoup, `aom-libs` not libaom, `libhwy`, `libidn2`, `libpciaccess`,
`pcre2`, `libunistring`).
