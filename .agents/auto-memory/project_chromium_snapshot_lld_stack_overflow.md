---
name: project_chromium_snapshot_lld_stack_overflow
description: a self-built clang toolchain's lld can carry PT_GNU_STACK memsz 0 (musl gives its threads a 128 KiB stack) vs Alpine's packaged lld23's 2 MiB; a big ThinLTO+CFI link (mksnapshot) overflows and SIGSEGVs deterministically; fix is -Wl,-z,stack-size=2097152 in the linker's own CMAKE_EXE_LINKER_FLAGS, not a build-time workaround
metadata:
  type: project
---

**Symptom (2026-09-17, `perf/chromium-cfi-snapshot-clang`, chain
35097888298 then resume 35282181912, both r7):** `mksnapshot`'s link (V8
snapshot generator, `--lto-O0`, cfi-icall + cfi-vcall on) died mid-link:

```
clang++: error: unable to execute command: Segmentation fault (core dumped)
clang++: error: linker command failed with exit code -2
```

818 s into the round, not the 6h GHA cap — deterministic on a resume from
the same image (same setup, same snapshot clang), ruling out flake.

**Root cause.** The chain's clang came from `ghcr.io/jclaveau/chs-clang`
(Dockerfile.clang, self-built to pin Chromium's exact revision), including
its own `bin/ld.lld`. `readelf -l` on that `lld` vs Alpine's packaged
`lld23` showed the self-built one's `PT_GNU_STACK` segment at **memsz 0**
— no explicit stack size requested at its own link time — while `lld23`'s
carries **2 MiB**. musl (unlike glibc) honors a 0/absent `PT_GNU_STACK`
request literally and gives spawned threads a **128 KiB** stack. A big
ThinLTO backend job under CFI (heavier IR, more call-graph state) run on
one of those 128 KiB threads overflows and segfaults. Alpine's own clang23
chain linked the identical target fine — same source, same flags, only the
linker binary differed, so this isolates the variable.

**Fix** (`ccc8534` on `perf/chromium-cfi-snapshot-clang`): add
`-DCMAKE_EXE_LINKER_FLAGS="-Wl,-z,stack-size=2097152"` to `Dockerfile.clang`
so the self-built `lld` itself gets a real `PT_GNU_STACK` request, and
repoint setup at the rebuilt toolchain image tag
(`…-alpine-55de724b2295`). This is a **setup-layer edit → the chain
restarts cold** ([[project_chromium_round_images_sha_keyed]]).

**How to apply:** when a self-built clang/lld toolchain crashes only on
large LTO/CFI links and only under musl, check `readelf -l <the linker
binary>` for `PT_GNU_STACK` memsz before suspecting the compile itself —
musl's small default thread stack turns an underspecified linker build
into a silent landmine that a glibc-hosted build of the same LLVM would
never hit.
