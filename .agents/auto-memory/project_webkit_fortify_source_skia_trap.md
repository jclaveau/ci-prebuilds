---
name: webkit-fortify-source-skia-trap
description: Alpine clang's _FORTIFY_SOURCE injects __memcpy_chk traps when SkAutoDescriptor::reset memcpys >12 bytes through a SkDescriptor* whose static-type size is 12 but actual storage is fStorage (~212B). Manifested as WPEWebProcess SIGILL at +14s during page creation.
metadata:
  type: project
---

WPEWebProcess crashes at +14s during PW SDK page creation on our Alpine/musl
WebKit build. Root cause: clang's `_FORTIFY_SOURCE` (Alpine default for
release builds at `-O2+`) replaces `memcpy(dst, src, n)` with
`__memcpy_chk(dst, src, n, __builtin_dynamic_object_size(dst))`. When
the compiler sees `memcpy(this->fDesc, &desc, size)` in `SkAutoDescriptor::
reset(const SkDescriptor&)`, the destination is a `SkDescriptor*` whose
static-type size is **12 bytes** (`sizeof(SkDescriptor) = fChecksum:4 +
fLength:4 + fCount:4`). The *real* backing storage is `this->fStorage`
(~212 bytes computed from `kStorageSize`), but the compiler can't see
that through the typed pointer.

For descriptors with `desc.getLength() > 12` (the common case — anything
with at least one Entry), the runtime check `n > 12` triggers
`__builtin_trap()` = **`0F 0B` (UD2)** = SIGILL.

**Identified by**:
- iter #5 of smoke-webkit-iter (core dump + post-mortem gdb)
- crash bt: `SkAutoDescriptor::SkAutoDescriptor(SkAutoDescriptor&&)+0xb4`
  called from `SkStrikeSpec::MakeCanonicalized` → `SkFont::getMetrics`
  → `WebCore::Font::platformInit` (Style::Resolver::initialize early in
  page creation)
- Disasm at trap site shows three conditions checked, then jmp to UD2:
  1. forward overlap `dst < src && dst+size > src`
  2. reverse overlap `src < dst && src+size > dst`
  3. **`size >= 13`** ← the trigger (`r14=0x4c=76`)
- Source: `Source/ThirdParty/skia/src/core/SkDescriptor.cpp`
  `SkAutoDescriptor::SkAutoDescriptor(SkAutoDescriptor&&)`
- WebKit pin: PW 1.60.0 → WebKit SHA `6b34ac51510516bd6a3ec2f5edc97413758d3ab1`

**Fix** (next rebuild):
- `cmake-flags.overlay`: `-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0` in both
  `CMAKE_C_FLAGS` and `CMAKE_CXX_FLAGS`
- Alternative source-level fix would be to cast `this->fDesc` to `void*`
  before passing to memcpy in `SkAutoDescriptor::reset`, but that's an
  upstream Skia change; build-flag fix is scoped to our build.

**Why this doesn't crash glibc PW prebuilts**: Microsoft's official PW
WebKit Linux build doesn't enable `_FORTIFY_SOURCE=3`. Alpine's gcc
hardening spec adds it by default; we inherit it through cmake's auto-
detection of compiler flags.

**Diagnostic infrastructure used**:
- `.github/workflows/smoke-webkit-iter.yml` — standalone dispatch
- core-dump capture path (host `core_pattern` + `--ulimit core=-1` +
  post-mortem gdb in same image)
- gdb-wrapper-on-WPEWebProcess approach was tried first (iter #4) but
  hung in batch mode — see [[set-e-masks-diagnostic-rc]] /
  [[timeout-no-signal-through-wrapper]]

Related:
- [[webkit-alpine-branch-c]] — pipeline design
- [[pw-webkit-inspector-pipe-crash]] — symptom-level notes; UPDATE this
  to point at the fortify root cause once the rebuild greens
