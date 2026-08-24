---
name: project_chromium_rounds_are_serial
description: r1..r12 cannot be parallelized — each round's Docker image IS the previous round's obj/ tree; the rounds are one serial ninja chopped up to fit GHA's 6h cap, so the levers are cores per round and a working sccache, not scheduling
metadata:
  type: project
---

`r2` declares `needs: r1` AND `BASE_IMAGE=…:chs-build-r1-sha-${{ github.sha }}`.
All twelve share one incremental ninja build dir; a round exists only to
continue the `obj/` tree the previous one left unfinished. Not an ordering
choice — a data dependency.

**The chopping costs nothing and saves nothing.** r1 ended 21:14:16, r2 started
21:14:19. The 25-30h is ninja's compile time on a 4-vCPU runner however you
slice it, so parallelizing rounds would not help even in principle. The split
exists solely because GHA kills a job at 6h.

**Levers, in order:**

1. **Cores.** `ninja -j $(nproc)`, `runs-on: ubuntu-latest` = 4 vCPU. A 16-vCPU
   larger runner cuts compile-bound work ~4x (~25h → ~7h, 2 rounds not 6-8).
   Larger runners are BILLED even on a public repo, so this is jean's call.
2. **sccache.** Kills the recurring tax instead of one build: any setup-layer
   edit forces a cold r1..r12 today. See [[project_sccache_ghac_readonly_v18]].
3. **Partitioning the ninja graph** across parallel jobs — rejected. Chromium's
   DAG is heavily shared so each partition rebuilds most of its transitive
   deps (total CPU multiplies), and recombining needs a merge of `.ninja_deps`,
   a binary depfile database with no merge tool.

Reducing the build itself is NOT a lever: PGO+ThinLTO are what make it slow and
they are the whole point ([[project_chromium_perf_arms_1_62]], geomean 1.42→1.12).

**How to apply:** when asked to speed the chain up, answer cores-or-cache, not
scheduling. [[project_chromium_from_source_split_build]],
[[project_chromium_round_images_sha_keyed]]
