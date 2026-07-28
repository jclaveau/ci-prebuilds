---
name: project_wk_webrtc_modernizr_resolved
description: WK modernizr datachannel/peerconnection/emoji RESOLVED via ENABLE_WEB_RTC source rebuild + font-noto-emoji + built-from-source gst webrtc plugin; sole residual is unicoderange (1 key).
metadata:
  type: project
---

**RESOLVED 2026-07-21** (WK artifact wk-sha-a5c818c6, rev 2287; conformance-webkit
29786915503 20/20 green). modernizr's `toEqual` on Alpine WebKit used to fail on
`datachannel:false`, `peerconnection:false`, `emoji:false`. Fix stack:

- **WebRTC**: force `ENABLE_WEB_RTC PRIVATE ON` in OptionsWPE.cmake + OptionsGTK.cmake
  via awk in `webkit/scripts/prep-source.sh` (it's a PRIVATE port value — a `-D` CLI
  override does NOT work, must edit source). `USE_GSTREAMER_WEBRTC` auto-follows
  (no libwebrtc). GTK also needs `USE_LIBRICE OFF` (Alpine has no librice). Adds
  `openssl-dev` to Dockerfile.source-prep (GStreamerChecks needs OpenSSL≥3).
- **Runtime webrtc plugin**: Alpine gst-plugins-bad OMITS the `webrtc` plugin
  (webrtcbin needs libnice≥0.1.23, Alpine ships 0.1.22). `conformance/build-runner.sh`
  has a `FROM alpine:edge AS webrtc-build` stage that builds libnice 0.1.23 + the gst
  webrtc plugin from source and COPYs libgstwebrtc into the runtime stage. Without it
  `new RTCPeerConnection()` throws → datachannel:false.
- **emoji**: `font-noto-emoji` in the WK runner apk list.

**`unicoderange` — ALSO FIXED 2026-07-21 (font-liberation, no rebuild).** It was NOT
a WebKit gap: Modernizr's test declares `@font-face{src:local("Arial");
unicode-range:U+0020,U+002E}` and reports false when `local("Arial")` can't resolve.
Alpine shipped no Arial; adding `font-liberation` to the WK runner (build-runner.sh)
makes fontconfig alias Arial→Liberation Sans → `local("Arial")` resolves → unicoderange
true. Validated locally (modernizr Safari Desktop passes). Both UA suites un-skipped.
So modernizr is now FULLY green — datachannel/peerconnection (WebRTC rebuild) + emoji
(font-noto-emoji) + unicoderange (font-liberation).

**Gotcha:** don't put literal backticks in a comment inside an UNQUOTED (`<<EOF`)
heredoc in build-runner.sh — the shell command-substitutes them at build time
(`line 243: new RTCPeerConnection()`), non-fatal but noisy. [[project_wk_media_gst_registry_env]]
[[project_webkit_alpine_branch_c]]
