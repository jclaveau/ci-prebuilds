---
name: wk-media-gst-registry-env
description: WebKit media codecs on Alpine were NOT structural — the WebProcess scanned an EMPTY GStreamer registry; fixed by setting GST_PLUGIN_SYSTEM_PATH_1_0/scanner/registry env in the conformance runner. Recovered play video/webm/audio + mp4.
metadata:
  type: project
---

WK `capabilities.spec.ts` media tests (`should play video/webm/audio`, `should
not crash on page with mp4`) were skip-listed as **STRUCTURAL** three times
(2026-07-16 gst-plugins-ugly/openh264 probe; 2026-07-18 sandbox re-probe;
2026-07-19 sandbox-off re-probe all "still fail, needs a WebKit build flag").
**All three verdicts were WRONG.**

Root cause: the WebKit **WebProcess built an EMPTY GStreamer plugin registry** —
`video.canPlayType('video/mp4;…')` returned `''` for EVERY codec, including
royalty-free vp8/webm. The decoders were INSTALLED (gst-plugins-* apks) but never
DISCOVERED, because the conformance runner never set the GStreamer plugin-path
env. `gst-inspect-1.0` in the same container saw avdec/vpx fine — only the
WebProcess's registry was empty.

**Fix (runner-config, NO WebKit rebuild):** in `conformance/build-runner.sh`
webkit case, after `PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1`:
```
ENV GST_PLUGIN_SYSTEM_PATH_1_0=/usr/lib/gstreamer-1.0
ENV GST_PLUGIN_SCANNER_1_0=/usr/libexec/gstreamer-1.0/gst-plugin-scanner
ENV GST_REGISTRY_1_0=/tmp/gst-registry.bin
```
Local probe: 5/5 media pass. Validated CI run 29683241904 (20/20 green).
`modernizr.spec` was ALSO un-skipped but re-skipped — its Safari-UA feature
detection diverges on WPE beyond codec sub-keys (genuine port delta, structural).

**How to apply:** any WPE/GTK GStreamer "no codecs / canPlayType empty / media
won't decode" symptom → check `GST_PLUGIN_SYSTEM_PATH_1_0` is set in the
*process that runs the browser*, BEFORE concluding a WebKit build-flag gap.
"Decoders installed but not discovered" = a plugin-path env miss, not a
build-flag miss. Cousin of [[feedback_config_first_layered_diagnosis]] and
[[project_pw_upstream_juggler_handshake_hang]]. Related:
[[project_webkit_alpine_branch_c]].
