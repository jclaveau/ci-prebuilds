---
name: project_pnpm_store_in_image
description: pnpm store baked into a CI image layer is 2x WORSE (links fail across bind mount → copies); store+node_modules prebuilt in image 0.65x CPU, 0.44-0.50x with verify off, image 3.4x (store stored twice); node_modules without store FAILS offline install; verify_store_integrity=false 0.85-0.90x (runs 41431180556, 41437119695, 2026-11-02)
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

**How to apply:** don't ship the store in an image layer. Cheapest real lever =
`pnpm_config_verify_store_integrity=false` where the store can't be corrupted (env
var name is pnpm_config_*, NOT npm_config_*). Related: [[project_pnpm_perf_gate]].
