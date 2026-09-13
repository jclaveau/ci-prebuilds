---
name: project_chromium_compiler_rt_move_breaks_clang22
description: edge's unversioned compiler-rt (23.1.1) unpacks under /usr/lib/llvm23 only — #208 swapped it in for clang22-rtlib, #210 linked the builtins archive back into clang22's resource dir, and #223 (2026-09-13) the sanitizer headers, after run 34576077869 died at r7 (30h in) on v8's unconditional <sanitizer/common_interface_defs.h>
metadata:
  type: project
---

alpine:edge dropped `clang22-rtlib` when it started packaging clang23 and now
serves every installed clang from one `compiler-rt` package whose files all
live under `/usr/lib/llvm23/lib/clang/23/`. clang22's own resource dir
(`/usr/lib/llvm22/lib/clang/22/`) therefore has neither the builtins archive
nor `include/sanitizer/`; `clang22-headers` carries no sanitizer headers
either (checked with `apk info -L`).

Two symptoms, months apart in the build:
- **builtins** — `ninja: file is missing … libclang_rt.builtins-x86_64.a`, 19 s
  into r1 (run 34498782299). Fixed #210 by symlinking the archive's directory.
- **headers** — `v8/src/sandbox/testing.cc:50: fatal error:
  'sanitizer/common_interface_defs.h' file not found`, at **r7, 30 h in**
  (run 34576077869, the SSP-via-cfg candidate, 2764/2951 edges of the round
  done). v8 includes it unconditionally; the build never enables a sanitizer,
  presence is all it needs. Fixed #223 by linking the directory beside the
  archive and compiling one TU through it at setup.

**Why it hid for a week:** every chain off main since #208 (2026-09-10) was
doomed at that object, but ninja only reaches it around r7 — the SSP chain was
the first to get that far. A setup-time assertion is worth more than any
round-time one here; both fixes end in a compile/link that fails in minute 1.

**How to apply:** when edge moves a toolchain package again, look for BOTH
halves (runtime archive and headers) and grep the setup stage's asserts.
aports' own chromium APKBUILD still lists `clang$_llvmver-rtlib` at
`_llvmver=22`, so there is no upstream recipe to copy.
[[project_chromium_clang23_lever]]
