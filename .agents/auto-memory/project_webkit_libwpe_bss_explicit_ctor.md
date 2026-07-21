---
name: project-webkit-libwpe-bss-explicit-ctor
description: WPEBackend-fdo's _wpe_loader_interface lambda-init reads NULL load_object in WebKit's main process on Alpine/musl; fix is an __attribute__((constructor)) patch on fdo.cpp
metadata:
  type: project
---

When WebKit's main process calls `wpe_load_object("_wpe_renderer_host_interface")`, libwpe aborts with:
```
libwpe [FATAL]: backend doesn't implement load_object vfunc
```

**Why:** libWPEBackend-fdo's `src/fdo.cpp` defines `_wpe_loader_interface` as a struct with a stateless-lambda first field:
```cpp
struct wpe_loader_interface _wpe_loader_interface = {
    [](const char* object_name) -> void* { ... },
};
```
On Alpine/musl with clang's codegen + LTO defaults, `nm -D` reports the symbol as `B` (BSS — uninitialized). Standalone `dlopen` populates `load_object` via the implicit static initializer (verified with a tiny C test calling dlopen+dlsym+read). But in WebKit's main process — where libwpebackend-fdo is loaded via MiniBrowser's `DT_NEEDED` — libwpe's `s_impl_loader = dlsym(handle, "_wpe_loader_interface")` returns a pointer to a struct whose `load_object` field reads NULL. Static initialization order, LTO, or cross-`.so` visibility interaction; never definitively root-caused.

**The fix.** Patch `src/fdo.cpp` to force populate via an explicit `__attribute__((constructor))`. File at `playwright/alpine-browsers/webkit/scripts/fdo-explicit-ctor.cpp`; `Dockerfile.source-prep` `cp`s it over the original before meson build:

```cpp
extern "C" {
__attribute__((visibility("default")))
struct wpe_loader_interface _wpe_loader_interface;

static void* fdo_load_object(const char* object_name) { /* same body */ }

__attribute__((constructor))
static void init_wpe_loader_interface(void) {
    _wpe_loader_interface.load_object = fdo_load_object;
}
}
```

**How to apply:** if the libwpe `_wpe_loader_interface` FATAL recurs after a libwpebackend-fdo upstream bump (1.16.x → 1.17+), the patch may need re-applying — diff `src/fdo.cpp` against our patched copy. Standalone test program: `dlopen("libWPEBackend-fdo-1.0.so.1") + dlsym("_wpe_loader_interface") + call ->load_object("_wpe_renderer_host_interface")`. Standalone works in isolation; if so the bug is the in-process loader interaction, not the lib itself.

**Walls iter'd through before landing the ctor patch** (kept for context, all confirmed NOT load-bearing):
- libwpe `-Ddefault-backend=libWPEBackend-fdo-1.0.so.1` meson option — useful but doesn't fix the BSS read.
- Upstream-master libwpe + libwpebackend-fdo build — same FATAL; version isn't the issue.
- WPEBackend-rdk HEADLESS as `libWPEBackend-default.so` (libwpe's fallback) — irrelevant; FATAL fires in main process, not subprocess.

Related: [[project-webkit-alpine-branch-c]] (parent), [[project-webkit-smoke-sandbox-strip-layers]] (next wall after libwpe).
