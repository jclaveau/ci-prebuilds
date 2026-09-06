---
name: project_alpine_clang_forces_ssp_strong
description: alpine clang 22 forces -fstack-protector-strong from the DRIVER, so the driver-level flag and --no-default-config are both inert — only `-Xclang -stack-protector -Xclang N` reaches cc1, and N=1 is exactly official chromium's posture
metadata:
  type: project
---

Our chromium ships **358 107** stack-protector canary loads against official's
**33 166** — counted on both shipped binaries
([[project_chromium_perf_record_first_read]]). Chromium asks for the WEAK
variant on linux (`-fstack-protector`, the `is_posix` branch of
`build/config/compiler/BUILD.gn`) and official's artifact agrees, so the
difference is Alpine's toolchain overriding chromium's intent.

**Alpine forces strong from the driver, and nothing at the driver level lifts
it.** Measured on `Alpine clang version 22.1.8` with a file carrying one char
array, one int array and one address-taken local — weak protects the char array
only, strong protects all three, so the two are distinguishable (a bench where
every function has an array reads the same under both, which is how an earlier
attempt got a useless all-4 result):

| flags | canary refs | level |
|---|---|---|
| default | 4 | strong |
| `-fstack-protector` | 4 | **strong — the flag is inert** |
| `-fstack-protector-strong` | 4 | strong |
| `--no-default-config` + any of the above | 4 | **still strong** |
| `-fno-stack-protector` | 0 | none |
| **`-Xclang -stack-protector -Xclang 1`** | **2** | **WEAK = official's** |
| `-Xclang -stack-protector -Xclang 2` | 4 | strong (control) |
| `-Xclang -stack-protector -Xclang 0` | 0 | none (control) |

`clang -O2 -### ` shows the driver handing cc1 `"-stack-protector" "2"`
regardless of what you pass. `--no-default-config` does NOT help even though
clang does load `/etc/clang22/x86_64-alpine-linux-musl.cfg`, so the default is
compiled into the driver rather than read from that file. Only `-Xclang` gets
past it.

**Use level 1, never `-fno-stack-protector`.** Turning it off entirely would
leave us LESS protected than the build we are chasing — a security regression
dressed as a perf fix. Level 1 is parity: the posture chromium asks for and
official ships. (An earlier brief in this campaign said `-fno-stack-protector`;
that was wrong and this is the version of record.)

**What it is worth:** the same flag change measured **+12.0% instructions
retired** on a call-dense kernel at an instrument spread of 0.015%, and our hot
layout regions carry **214 protected functions per 64 KiB against official's
19**. Note the +12.0% was strong-vs-OFF, so weak-vs-strong recovers somewhat
less — but weak should land the artifact near official's 33 166, i.e. most of
the difference.

**How to apply:** through the ENVIRONMENT, not a gn arg. We build with
`custom_toolchain = "//build/toolchain/linux/unbundle:default"` and that
toolchain reads `extra_cflags = getenv("CFLAGS")` /
`extra_cxxflags = getenv("CXXFLAGS")` — the same mechanism as the CC/CXX/AR/NM
exports `apply-and-build.sh` already sets. `stage-cache-layout.sh` prints the
linked binary's canary count so a build that silently ignored the flag is
visible as a null arm instead of shipping as a result
([[feedback_verify_ab_varied_the_variable]]).
