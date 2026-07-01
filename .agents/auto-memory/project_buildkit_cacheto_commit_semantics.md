---
name: buildkit-cacheto-commit-semantics
description: BuildKit's `cache-to=type=registry,mode=max` only pushes when the docker buildx build exits NORMALLY; cancelled/killed builds publish nothing → next iter starts cold even on the same commit
metadata:
  type: project
---

`docker/build-push-action` with `cache-to: type=registry,ref=…,mode=max` does NOT push cache layers progressively as each RUN completes. The export step runs at end-of-build. If the build is killed mid-flight (GHA 6h hosted-runner cap, manual cancel, OOM), the cache-to push is killed too. Registry stays empty. Next iter on the same commit starts from scratch.

**Signature:** subsequent iter's log shows `ninja round-1 — starting with 0 .o files on disk` despite the prior iter having compiled 13044 .o files; or `cache importer: ghcr.io/<repo>:buildcache: not found` even after many runs that hit the cap.

**Why:** BuildKit batches the cache export at end-of-build. There is no `--cache-to-flush-frequently` mode. The cache layer for a successful RUN is written to local BuildKit storage, but the registry push happens after the whole build resolves.

**How to apply:**
- A multi-RUN split-build approach (rounds with `timeout 18000 ninja`) does NOT solve a >6h build because the registry push happens only after the final RUN. If the final RUN gets capped, NONE of the prior rounds' cache reaches the registry.
- Fix forward: make the build small enough to fit in the cap, so it can complete and publish ONCE. Future iters then warm-resume.
- Shrink levers for chromium-headless-shell: `enable_webrtc=false`, `skia_use_dawn=false`, `use_dawn=false`, `skia_use_vulkan=false`, `angle_enable_vulkan=false` — chops the top compile-count subdirs (xnnpack, webrtc, dawn, angle, vulkan) which PW SDK never touches.
- Diagnose compile distribution from in-progress logs with `gh api .../jobs/<id>/logs | grep -oE 'obj/[^/]+/[^/]+' | sort | uniq -c | sort -rn`.

Related: [[project_chromium_from_source_split_build]] (the original split approach, now superseded by feature-cut strategy).
