---
name: project_chromium_from_source_runtime_deps
description: Validated Alpine apk package list for from-source chrome-headless-shell (chromium 148 on musl); iterating this list is what unblocked v27
metadata:
  type: project
---

Alpine apk pkgs required to `chrome-headless-shell --version` on the from-source binary (chromium 148.0.7778.96 built against alpine:edge). Validated locally against `chs-sha-a792691...`.

```
nss freetype harfbuzz ca-certificates ttf-freefont libdrm mesa-gl
libwebp libwebpdemux libxcomposite libxdamage libxrandr libxscrnsaver libxtst
libx11 libxcb libxext libxi cups-libs alsa-lib dbus-libs pango cairo
opus dav1d ffmpeg-libavformat libjpeg-turbo libxslt
libatk-1.0 libatk-bridge-2.0 at-spi2-core minizip
double-conversion crc32c libxkbcommon mesa-gbm eudev-libs flac
harfbuzz-subset
```

**Why:** Chromium 148 links against ~35 shared libs at runtime; missing any produces `Error relocating` at first exec. The names diverge from Debian/Ubuntu (`libatk-1.0` not `libatk1.0-0`; `mesa-gbm` not `libgbm1`; `harfbuzz-subset` is separate pkg not bundled in `harfbuzz`).

**How to apply:** For any downstream Alpine consumer image that copies the `/chrome-headless-shell-linux64` tree out of `ghcr.io/jclaveau/playwright-alpine-browsers:chs-sha-*`, install the full list above. If new deps appear (chromium version bump), iterate locally per [[feedback_iterate_deps_locally_before_ci_rebuild]] — `docker run --rm <image> /opt/chs/chrome-headless-shell --version` reports missing libs in seconds.

Related: [[feedback_verify_pkg_names_locally]].
