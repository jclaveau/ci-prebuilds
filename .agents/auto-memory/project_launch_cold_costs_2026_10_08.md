---
name: project_launch_cold_costs_2026_10_08
description: Per-launch / per-container costs found 2026-10-08 on famille — lavapipe ICD in chromium GPU proc (aa781a1), shim dirname fork (636a781), GStreamer registry scan on first WebKit launch (ac64224), coreutils exec 1.9 ms over busybox (libcrypto)
metadata:
  type: project
---

All measured on famille-laptop (i3-4005U), perf-alpine:counted (sha-1a9cf49).

- **Lavapipe in chromium GPU process** — mesa-vulkan-swrast (added for WebKit, #82) puts
  lvp_icd in /usr/share/vulkan/icd.d; ANGLE init 118-145 ms vs 33-57 ms with
  VK_ICD_FILENAMES=swiftshader. Interleaved launch: 247.8 vs 240.5 ms median, p90
  270.2 vs 254.6. SHIPPED aa781a1 (shim sets VK_ICD_FILENAMES unless caller does).
  WebKit maps lvp too but noicd interleave 0.99x, variable unverified → not shipped.
- **Shim `$(dirname "$0")`** → `${0%/*}`: 9.4 vs 5.4 ms per shim exec. SHIPPED 636a781.
- **GStreamer registry**: first WebKit launch per fresh container 763 vs 130 ms
  (official 1358 vs 148). Baked registry + GST_REGISTRY in shim → 145-161 ms for
  root / non-root / passwd-less uid. frei0r (0 features) had to go: it depends on
  $HOME/.frei0r-1/lib, so a registry baked under root forced a ~20 ms rescan for any
  other user. SHIPPED ac64224. Conformance runner keeps the scan path (by choice).
  REGRESSED: CI's image finds the baked file stale (gio entry; 238 vs 238 plugins,
  2-byte binary diff, cause unknown), and a read-only GST_REGISTRY can't be rewritten
  -> rescan EVERY launch: warm 145.7 vs 123.5 ms; TP 37851214532 webkit launch 1.22x
  vs budget 1.20. FIX 3254ba3 (local, unpushed 2026-10-09): shim cp's the bake to
  ${XDG_CACHE_HOME:-~/.cache}/gstreamer-1.0/registry.x86_64.bin if absent and no
  GST_REGISTRY/GST_REGISTRY_1_0 set -> first 168-216 ms, warm 124.1-125.2 ms.
  Rule: never point GST_REGISTRY at a read-only file.
- **coreutils exec costs ~3.0 ms vs busybox 1.1 ms** (official /bin/true 0.85 ms):
  Alpine coreutils links libcrypto.so.3 + acl/attr/utmps/skarnet. Remaining per-launch
  coreutils execs after 636a781: WebKit only (upstream pw_run.real.sh: 2 uname +
  1 dirname, ~6 ms of ~515 ms). Not acted on.

**Why:** these are launch-path costs perf-probe's warm launch row may not see (first
launch per container is what a CI consumer pays).
**How to apply:** for launch work, strace -f execve/open on one launch per browser
first (musl uses `open`, not `openat`); compare first vs later launches in a fresh
container. busybox `date` has no %N — time loops with coreutils date or node.
Counted harness gotcha: count-arms.sh only attaches perf to a candidate NAMED
`official`; and counted launch runs drift in time — use interleaved in-container A/B.
