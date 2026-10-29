---
name: WebKit mixed-distro launch 9x was a laptop artifact
description: 24.04 WebKit build on the 26.04 image reads at parity in CI (n=100 x3); the plain cross-distro mix cannot launch at all (ICU soname), nothing shipped mixes distros
type: project
---
Laptop read 1792-1830 vs ~200 ms CPU per launch (node 204.8 vs 9.5 ms) for the
26.04 image running the 24.04 webkit-2336 build. CI does NOT reproduce it.

Probe: `.github/workflows/wk-mixed-launch-probe.yml` (dispatchable), run
40960385702, 3 replicates, 10 rounds x 10 launches interleaved, PMU=0 on hosted
runners (CPU-ms only). Medians, mix vs u26own:

| CPU | arm | wall | node CPU | cgroup CPU |
|---|---|---|---|---|
| EPYC 7763 r1 | u26mixicu | 79.6 vs 79.6 ms (1.00) | 6.8 vs 6.7 ms (1.01) | 88.9 vs 89.2 ms (1.00) |
| EPYC 7763 r1 | u26mixicucopy | 80.7 vs 79.6 ms (1.01) | 7.1 vs 6.7 ms (1.06) | 90.1 vs 89.2 ms (1.01) |
| EPYC 7763 r2 | u26mixicu | 80.8 vs 80.3 ms (1.01) | 6.9 vs 6.8 ms (1.02) | 89.7 vs 89.6 ms (1.00) |
| EPYC 7763 r2 | u26mixicucopy | 80.9 vs 80.3 ms (1.01) | 6.8 vs 6.8 ms (1.00) | 90.0 vs 89.6 ms (1.00) |
| Xeon 6973P-C r3 | u26mixicu | 53.5 vs 55.1 ms (0.97) | 5.1 vs 5.4 ms (0.94) | 59.8 vs 62.7 ms (0.95) |
| Xeon 6973P-C r3 | u26mixicucopy | 54.9 vs 55.1 ms (1.00) | 5.4 vs 5.4 ms (1.01) | 61.8 vs 62.7 ms (0.98) |

Diagnostics identical across arms: 49 execve / 3 launches, ~19.9k syscalls
(`strace -f -c`), 43 DEBUG lines, cpu-prof top = idle + loader wrapSafe ~97 ms.

- The PLAIN mix cannot launch either way: 24.04 build on 26.04 =
  `libicudata.so.74: cannot open`, 26.04 build on 24.04 = `libicudata.so.78`.
  A cross-distro PW_BROWSERS cache fails loudly, never slowly.
- `u26mixicu` = the 24.04 build + 24.04's libicu*.so.74 + libxml2.so.2 copied
  into `minibrowser-wpe/sys/lib` (mounted); `u26mixicucopy` = same tree baked into
  the image. The laptop's tree had been hand-patched the same way, so the 9x is
  a laptop-conditions artifact (jean's laptop), not the build mix.
- Exposure: none. Ubuntu images run `playwright install --with-deps` per base
  image; no workflow caches the browsers dir across distros.
- Side reading: u26own vs official 1.10-1.11 cgroup CPU here because the
  workflow's default `image_u26` is `:latest` = 3d61adb, built BEFORE b12e8f0
  (still uutils). Expected; see [[project_wk_ubuntu_launch_real_1_10]].

**How to apply:** do not chase a mixed-distro webkit launch gap; if it resurfaces,
rerun wk-mixed-launch-probe with `image_u26` pinned to a post-b12e8f0 sha tag.
