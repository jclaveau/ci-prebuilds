---
name: project_ff_conformance_video_edge_ffmpeg9
description: conformance-firefox "should play video" hangs 30s because the alpine:edge runner ships ffmpeg 9 (libavcodec.so.63), which FF 153 cannot dlopen; Theora is gone too, so no source plays
metadata:
  type: project
---

Red since run 42810687753 (2026-11-10, commit 2a49dc5, unrelated to it): `capabilities.spec.ts:69 should play video` times out at `v.play()` on every retry.

Chain, each link checked in source / APKINDEX on 2026-11-17:
- fixture `video.html` = `<source movie.mp4>` then `<source movie.ogv>`
- runner `build-runner.sh` firefox case is `FROM alpine:edge` → ffmpeg-libavcodec 9.0.2 = `so:libavcodec.so.63`
- FF 153 `FFmpegRuntimeLinker.cpp` tries `.so.62` (FFMPEG_MAX_MAJOR_VERSION) down to 53 → no system ffmpeg → no H.264
- FF 153 `OggDecoder` = opus/vorbis/flac only, ffvpx `CONFIG_THEORA_DECODER 0` → ogv fails too
- all `<source>` fail → element waits for a new source forever, the play() promise never settles → hang, not an error

Shipped image is on 3.24 (alpine-gha-tools OS_VERSION), where gst-libav pulls `libavcodec.so.62` (ffmpeg 8.1.3) → mp4 should play there. The red is runner drift: the runner tests edge libs, not the shipped ones (see [[project_conformance_runner_mirrors_consumer]]).

**Why:** edge moved ffmpeg 8 → 9 on 2026-10-24; firefox conformance was path-filter-skipped until 2026-11-10, so the drift surfaced late.
**How to apply:** fix the runner's libs (match the consumer's base), never skip the test ([[feedback_never_skip_conformance_tests]]). The same edge drift can red any FF media test whenever edge bumps a dlopen'd soname past FF's list.
