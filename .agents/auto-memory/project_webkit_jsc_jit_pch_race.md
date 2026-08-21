---
name: webkit-jsc-jit-pch-race
description: WebKit 4d05d732's new JavaScriptCoreJIT subtarget has a PCH that does not depend on JavaScriptCore_CopyPrivateHeaders — cold+parallel builds die on 'JavaScriptCore/FPRInfo.h' file not found; fix is pre-building the header-copy targets
metadata:
  type: project
---

Moving the base to WebKit 4d05d732 killed `build-webkit-wpe-1` 26 minutes in, at
unit 6601/8797:

```
B3ValueRep.h:32:10: fatal error: 'JavaScriptCore/FPRInfo.h' file not found
```

**It is a missing dependency edge, not a missing file** — ninja logged
`Generating .../PrivateHeaders/JavaScriptCore/FPRInfo.h` 19s *before* the
failure; the PCH job had started earlier and resolved its includes first.

Cause: 4d05d732 introduced
`WEBKIT_DEFINE_SUBTARGET_WITH_PREFIX(JavaScriptCore JavaScriptCoreJIT PREFIX
JavaScriptCoreJITPrefix.h ...)`, whose precompiled header has no dependency on
`JavaScriptCore_CopyPrivateHeaders`. The old base has **0** references to that
subtarget in JSC's `CMakeLists.txt` against **2** at 4d05, which is why this only
appeared when the base moved. A cold sccache (0 hits) plus full parallelism is
what lets the PCH win the race.

**Fix** (`apply-and-build-port.sh`, before Phase 2): build
`WTF_CopyHeaders`, `bmalloc_CopyHeaders`, `JavaScriptCore_CopyPrivateHeaders`
first. Deterministic — unlike lowering `-j` or retrying the compile, which only
make a race less likely. No-ops on resume rounds; a rename upstream degrades to a
note because the real build still gates the round.

Applies to both ports: WPE and GTK share JavaScriptCore.
