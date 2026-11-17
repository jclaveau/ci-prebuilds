---
name: project_wk_shipped_image_lacked_webrtc_plugin
description: shipped alpine WebKit threw on new RTCPeerConnection() while conformance-webkit was green — only the runner built gst's webrtc plugin; now one build-webrtc.sh for both + a post-publish probe
metadata:
  type: project
---

2026-11-17, `webrtc-shipped-probe.yml` run 44065991939 on the published `*-dood-playwright:latest`:

| image | webkit | chromium | firefox |
|---|---|---|---|
| alpine | `InvalidAccessError: Bad Configuration Parameters` at the constructor | ok | ok |
| ubuntu | ok (offer has `m=application`) | ok | ok |

On disk: alpine had only `libgstwebrtc-1.0.so.0` (the library), no `gstreamer-1.0/libgstwebrtc.so` (webrtcbin) and no libnice; ubuntu had both.

Cause: Alpine's gst-plugins-bad omits webrtcbin (gst 1.28 needs libnice >= 0.1.23, Alpine 0.1.22). `build-runner.sh`'s `webrtc-build` stage built it for conformance only; `playwright/Dockerfile.alpine` never did. Same shape as [[project_conformance_runner_mirrors_consumer]]: the runner proved a browser nobody shipped. Chromium/firefox carry their own WebRTC stacks, so only webkit was hit.

Fix adccaad: recipe moved to `playwright/alpine-browsers/webkit/webrtc/build-webrtc.sh` (zlib-ng pattern: build stage → COPY into `runtime-libs`), the registry bake runs `gst-inspect-1.0 webrtcbin` so a missing plugin fails the build, TP's paths-ignore carves the dir out ([[project_tp_paths_ignore_ships_nothing]]), and the probe reruns on every successful Test and Publish on main.

Same day, d51d6a1: every conformance runner stage runs on `RUNNER_ALPINE` (= alpine-gha-tools OS_VERSION, Renovate bumps both in the "Alpine base image" PR), after edge drift redded firefox ([[project_ff_conformance_video_edge_ffmpeg9]]).

**Why:** a runner-only fix makes conformance green on a gap consumers still hit.
**How to apply:** anything the runner adds to make a test pass must come from a script `Dockerfile.alpine` also runs; when a runner stage installs/builds something, grep the consumer for it.

**Verified 2026-11-17:** TP 44090648344 (bdbe001) published latest; WebRTC shipped-image probe 44094198898 green on all 6 legs, alpine webkit included.
