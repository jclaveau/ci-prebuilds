---
name: parked_node_driver_mimalloc_insecure_security
description: PARKED security note — 2026-10-06 the consumer image's container-wide LD_PRELOAD moved from libmimalloc-secure to -insecure for speed (eval_rtt 0.93x); revisit the hardening trade-off later, not now
metadata:
  type: project
---

jean 2026-10-06: "go mimalloc insecure but we'll have to note it regarding
security in the future (not our concern for now)".

**What changed:** `playwright/Dockerfile.alpine` `ENV LD_PRELOAD` →
`/usr/lib/libmimalloc-insecure.so.2` (was `libmimalloc.so.2` → secure).

**What it gives up:** mimalloc secure mode's guard pages, encoded free-list
pointers, double-free detection, randomised allocation order. A heap bug in
node's native code (V8, libuv, OpenSSL, native addons) becomes silent
corruption instead of an early crash.

**Scope to remember:** the ENV is container-wide, so it reaches EVERY process a
user runs in the image (npm, shell, the app under test), not just the
Playwright driver. Chromium's launcher unsets it; firefox and webkit launchers
already preload -insecure on their own.

**Why it was acceptable:** official PW image (v1.62.1-noble) preloads no
allocator — node runs glibc ptmalloc2 (pointer mangling + tcache double-free
check, no guard pages, no randomisation), so -insecure is not meaningfully below
official. Measured: [[project_chromium_nav_input_local_levers_2026_10_01]]
(eval_rtt 297 vs 318 ms, one local counted draw; old CI A/B 33066499518 read ~2%).

**When to revisit:** any security-hardening pass on the default tags, issue #259
follow-ups, or the *-for-testing split ([[parked_for_testing_image_family]]) —
options then: scope the preload to the driver only via a node wrapper, or go
back to secure on the default tag.

**Package dropped too (2026-10-06, jean "keep only mimalloc insecure"):**
`mimalloc2` (the secure build, 207 KiB) is no longer installed in
Dockerfile.alpine's runtime-libs stage. Going back to secure = re-add
`mimalloc2` to that apk list AND point the ENV at `libmimalloc.so.2`.
