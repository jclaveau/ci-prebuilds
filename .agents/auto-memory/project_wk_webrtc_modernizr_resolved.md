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

**Sole residual — `unicoderange: false`** (expected true): a CSS `@font-face`
`unicode-range` font-feature-detection gap in the musl WebKit build, unrelated to
WebRTC. modernizr's `toEqual` is all-or-nothing so this one key still fails the two
UA suites → `Safari Desktop` / `Mobile Safari` title-skipped in webkit.titles.txt.
datachannel + peerconnection now compile + work (future direct-RTC tests will pass).

**Gotcha:** don't put literal backticks in a comment inside an UNQUOTED (`<<EOF`)
heredoc in build-runner.sh — the shell command-substitutes them at build time
(`line 243: new RTCPeerConnection()`), non-fatal but noisy. [[project_wk_media_gst_registry_env]]
[[project_webkit_alpine_branch_c]]
