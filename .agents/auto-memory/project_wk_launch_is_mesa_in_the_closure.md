---
name: wk-launch-is-mesa-in-the-closure
description: RESOLVED — WebKit's launch row was Alpine's libEGL DT_NEEDing libgallium+libLLVM (235 MB) into every process (no libglvnd); USE_GSTREAMER_GL=OFF shipped it 1.47 -> 0.88
metadata:
  type: project
---

`launch` sat at 1.32–1.45 for months. It is not the loader being slow — it is
**what our loader is asked to load**.

Alpine has no libglvnd. Ubuntu's `libEGL.so.1` is a dispatch stub that dlopens
the Mesa driver on first use; Alpine's `mesa-egl` **is** `libEGL.so.1`, and it
`DT_NEEDED`s `libgallium` (44 MB), which `DT_NEEDED`s `libLLVM` (191 MB). musl
has no lazy binding, so all of it is mapped and relocated before `main` runs —
in each of the three processes a launch starts.

The only edge reaching libEGL is **libWPEWebKit's link against libgstgl**.
Playwright's build has the same edge and pays nothing for it, because on their
side the chain stops at the glvnd stub.

Measured, by stubbing libEGL/libGL in the shipped image (generate `void f(){}`
for every `nm -D` defined symbol, drop `_init`/`_fini`, overwrite in /usr/lib):

| | shipped | stubbed |
|---|---|---|
| closure objects | 124 | 107 |
| `ld.so --list` | 70 ms | 36 ms |
| `MiniBrowser --version` | 121 ms | 64 ms |

Closure totals, ours vs Playwright's: 124 vs 139 objects, but **36 040 vs
20 273 symbol relocations** — and glibc resolves only what gets called.

**Why:** every other launch candidate measured flat — DSO closure (ours is
smaller), BIND_NOW, DT_RELR (3%), lazy binding (musl has none), and the
unwinder counted zero throws and zero walks across 1108 processes. See
[[project_wk_launch_is_the_loader]] for the dead ends.

**How to apply:** the fix is `-DUSE_GSTREAMER_GL=OFF` (PR #180) — WebKit still
reaches GL through libepoxy, which dlopens. When a startup cost resists every
build flag, audit what is in the closure that does not need to be, with
`ld.so --list <bin>` and a per-DSO `DT_NEEDED` scan; a stub library prices the
removal in minutes instead of a multi-hour rebuild.

**2026-09-08 — SHIPPED and CONFIRMED.** `-DUSE_GSTREAMER_GL=OFF` plus a
`patch_dmabuf_without_gstreamer_gl` hunk in prep-source.sh (the DMABuf enumerator
and `gst_dmabuf_memory_get_fd` were guarded by `USE(GSTREAMER_GL)` upstream and
break the build without it) merged as PR #180. Producer run 34189647309 green
including every conformance-webkit shard.

n=10 with the `latest` control in the SAME job (run 34213377452):
**launch 67.6 arm vs 101.5 control vs 77.4 official — 1.31 -> 0.87.** Confirmed
again on the combined image at 0.88 (run 34220856269).

The stub experiment predicted this almost exactly, at minutes of cost against a
4-hour rebuild. Stub-price a closure removal before building it.
