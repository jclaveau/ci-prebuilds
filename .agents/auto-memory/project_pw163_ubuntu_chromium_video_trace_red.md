---
name: project_pw163_ubuntu_chromium_video_trace_red
description: PW 1.63.0's renovate branch reds conformance-ubuntu-chromium on video.spec.ts:764 "should work with video+trace" — official image, official test, our builds not involved
metadata:
  type: project
---

`renovate/playwright` (PR #234, PW **1.62.1 → 1.63.0**) reds
`conformance-ubuntu-chromium` on one test, all three attempts:

```
tests/library/video.spec.ts:764:40  screencast › should work with video+trace
TypeError: Cannot read properties of undefined (reading 'file')
  const frame = events.filter(e => e.type === 'screencast-frame').pop();
  const buffer = resources.get(frame.file);   // frame is undefined
```

`events` carries no `screencast-frame`, so the trace recorded no video frame.
The leg runs `mcr.microsoft.com/playwright:v1.63.0-noble` — official image,
official test, official chromium. **Nothing of ours is under test here.** The
shard moves between runs (18 in run 35999968902, 2 in 35917157622) because the
failure follows the test, not the shard.

The Alpine leg never sees it: `skip-list/chromium.titles.txt` file-skips
`screencast/video.spec.ts` outright, and `skip-list-ubuntu/chromium.titles.txt`
does not.

**How to apply:** this is the PW 1.63 bump's blocker, not a browser-build
regression — do not chase it in an Alpine build. Closing it is a ruling: add the
title to `skip-list-ubuntu/chromium.titles.txt` (the Ubuntu baseline is a
control, not a product) or hold #234 until upstream fixes the trace. Related:
[[project_pw_test_annotations_shape_conformance]].
