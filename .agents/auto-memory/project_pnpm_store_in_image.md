---
name: project_pnpm_store_in_image
description: CLOSED 2026-11-05 by jean, not worth the complexity — deps image (store+node_modules prebuilt) LOSES to actions/cache on GHA; one clock empty image store → installed on Scalabus (Planner proxy, run 42030366706): cache path 15.5-17.2 s vs onerun 31-33 s (1.9-2.0x) vs deps 37-43 s (2.3-2.5x); earlier split timings onerun +11-14 s/job, deps_layer +13-17 s/job (pull 23-27 s vs base 4-5 s + cache restore 5-7 s; install saves only 0.2-0.3 s; runs 42000096479, 42001923638, 42015437056); pnpm store baked into a CI image layer is 2x WORSE (links fail across bind mount → copies); store+node_modules prebuilt in image 0.65x CPU, 0.44-0.50x with verify off, image 3.4x (store stored twice); node_modules without store FAILS offline install; verify_store_integrity=false 0.85-0.90x (runs 41431180556, 41437119695, 2026-11-02)
metadata:
  type: project
---

Probe `pnpm-install-probe.yml` mode=store_layer, run 41431180556 (2026-11-02),
alpine-dood-pnpm pnpm 12.16.1, vitest fixture offline install, 10 rounds,
2x EPYC 9V74 + 1x 7763. CPU = cgroup user+sys, medians, vs `bind` (store on the
/w bind mount beside the project, today's layout):

| arm | CPU | wall |
|---|---|---|
| bind_noverify (`pnpm_config_verify_store_integrity=false`) | 0.86-0.90x | 0.90-0.97x |
| store_layer (store at /opt/store in the image, project on bind) | 2.00-2.08x | 1.44-1.79x |
| store_layer_noverify | 1.86-1.99x | 1.38-1.80x |
| deps_layer (node_modules installed in the image at /app) | 0.64-0.66x | 0.85-0.88x |

- store_layer: linkat 68,062 → 49, open 6.7k → 143k: every file copied
  (EXDEV across overlay vs bind mount). Dead.
- deps_layer is NOT a no-op: still ~49k stat (the store verifier) + 1,409 linkat.
- Image size uncompressed vs base 192 MB: store_layer 473 MB (2.47x, incl. ~94 MB
  metadata cache), deps_layer 658 MB (3.43x; the build-time link copies up the
  store files into the RUN layer, metacopy=N). Pull time not measured; it likely
  eats the deps_layer saving (~1.1 s CPU, ~0.2 s wall).
- An offline pnpm 12 install needs the metadata cache (`$HOME/.cache/pnpm`) for its
  lockfile supply-chain check (ERR_PNPM_NO_OFFLINE_META without it): a store image
  must ship it too.
- Hosted runners: storage driver overlayfs (containerd snapshotter), metacopy N.

Run 41437119695 (9V74, 7763, Xeon 8370C), CPU / wall vs bind:
deps_layer 0.65-0.70x / 0.87-0.89x; deps_layer_noverify 0.44-0.50x / 0.73-0.77x
(stat 49,095 → 3,448). modules_layer (node_modules in image, store emptied in the
same RUN, 473 MB) FAILS the offline install: ERR_PNPM_NO_OFFLINE_TARBALL
"snapshot not present in local store", even with node_modules up to date and
verify off. So `pnpm install` always needs the store; an image without it only
works if CI skips `pnpm install` entirely. deps_layer's 658 MB is the store twice
(COPY layer + copy-up in the install RUN); copying the store and installing in ONE
RUN would keep hardlinks: est. ~473 MB, not measured.

Runs 42000096479 + 42001923638 (2026-11-05, mode=deps_image, 10 rounds x 3):
onerun_layer = seed /opt/store from the previous store, install, `pnpm store
prune`, all in ONE RUN (hardlinks kept). Wall / CPU vs bind:

| CPU | deps_layer_noverify | onerun_layer_noverify |
|---|---|---|
| 8370C | 880 vs 1125 ms (0.78x) / 0.52x | 950 vs 1125 ms (0.84x) / 0.54x |
| 7763 | 971 vs 1303 ms (0.75x) / 0.43x | 1128 vs 1303 ms (0.87x) / 0.48x |
| 9V74 | 1082 vs 1506 ms (0.72x) / 0.45x | 1096 vs 1506 ms (0.73x) / 0.49x |

- onerun image 497 vs 668 MB deps_layer (0.74x); +306 vs +477 MB over base.
  onerun has 63k vs 25k page faults (2.5x) vs bind, still faster.
- linked_layer (symlink /app's node_modules into the checkout, "option B"):
  third-party deps resolve, but WORKSPACE packages resolve to the image copy
  (`@vitest/expect` → /app/packages/expect): stale code for monorepos. Dead
  unless the repo has no workspace packages.
- Cold pull on a fresh runner (9V45 x2, 7763), median of 3: deps image 19.2-24.8 s
  vs base 4.3-4.9 s → +14.8-19.8 s. actions/cache restore of the same store +
  metadata (1.07 GB uncompressed): 4.4-8.0 s. Pull is extraction-bound (68k
  small files), not bytes-bound. That 19.2-24.8 s was the onerun image (497 MB).
- deps_layer image (668 MB) pull, run 42015437056 (7763 x3), median of 3:
  26.3-26.8 s vs onerun 23.2-24.1 s vs base 4.4-5.4 s vs cache restore 5.1-7.3 s.
  Net vs cache path: deps_layer +13.4-16.5 s per job, onerun +11.2-13.5 s.
- Net on a cold GitHub-hosted runner: deps image +15-20 s pull for -0.2-0.4 s
  install vs cache restore 4-8 s. **The deps image loses by ~10 s per job.** It could
  only win where the image is already local (act, self-hosted, a runner that keeps
  layers).
- Scalabus fixture (jclaveau/directus c4b8ce7, 2452 packages, 95k node_modules
  files, ignoreScripts), run 42024429400 (7763 x2, 9V74), medians: install bind
  1792-1980 ms vs onerun/deps 970-1170 ms (saves ~0.8 s); pull onerun 28.5-29.3 s
  vs deps 33.1-34.1 s vs base 4.7-5.5 s vs cache restore 5.2-6.7 s (0.98 GB).
  Net vs cache path: onerun +15.6-18.2 s/job, deps +20.8-22.4 s/job — WORSE
  than vitest: the pull grows with file count faster than the install saving.
  Planner itself (4940 packages linked, CI run 42014916214) is ~2x Scalabus.
- One clock per path, empty image store → installed (run 42030366706, Scalabus,
  9V74/7763/9V74, median of 3, verify off on all): cache path (restore + base
  pull + start + install) 15.5/17.2/17.1 s vs onerun 31.2/32.7/32.8 s (1.9-2.0x)
  vs deps 37.4/39.0/42.6 s (2.3-2.5x). Start+install right after a cold pull is
  NOT the 1 s of the warm loop: cache 3.1-5.3 s, onerun 1.8-4.5 s, deps 4.3-9.4 s
  (freshly extracted files, cold page cache).
- Warm vs cold, so a later reader does not mix them: the 0.44-0.65x CPU and
  970-1170 vs 1792-1980 ms install figures are WARM (image already local, store
  full); only act/self-hosted ever sees that. Hosted GHA always pays the cold pull.
- **Verdict, jean 2026-11-05: closed, not worth the complexity** — no deps image,
  not even an act-only one. Probe code stays on branch `probe/deps-image` and in
  `node/bench/pnpm-install-probe.sh` (`mode=deps_image`); ghcr `pnpm-probe-deps`
  deleted.

**How to apply:** keep actions/cache for the pnpm store, on GHA and act alike. Do
not re-propose an image holding the store and/or node_modules unless the runner
model changes (persistent self-hosted daemon). Don't ship the store in an image layer. Cheapest real lever =
`pnpm_config_verify_store_integrity=false` where the store can't be corrupted (env
var name is pnpm_config_*, NOT npm_config_*). Related: [[project_pnpm_perf_gate]].
