#!/usr/bin/env bash
# Consumer-side dedup of Mesa's software-GL closure from a bundled WebKit port.
#
# bundle-dist.sh walks DT_NEEDED and bundles Mesa's software renderer stack
# (libgallium -> libLLVM + SPIRV-Tools + EGL/GL/gbm/drm/X11/xcb) into the
# self-contained artifact. In consumer images whose base already installs Mesa
# via apk (the combined dind/dood image + the conformance runner), those copies
# are pure duplication: the bundle's RPATH=$ORIGIN resolution falls back to
# /usr/lib for anything it no longer carries, so the apk Mesa (a fresh edge
# snapshot, newer than the build-time one) satisfies every dep. ~225 MB on-disk
# saved per bundle.
#
# The producer artifact stays Mesa-intact (FROM scratch, no apk to fall back
# to) — this script is applied to the COPY'd bundle on the consumer side, after
# the apk Mesa install.
#
# Usage: strip-mesa-closure.sh <bundle_dir>
# Idempotent (no-op when the closure is absent). Fails if any remaining ELF
# still has unresolved deps — a removed lib the apk doesn't provide surfaces
# here instead of at browser launch.

set -euo pipefail

DST="${1:?usage: strip-mesa-closure.sh <bundle_dir>}"
[ -d "$DST" ] || { echo "strip-mesa-closure: $DST is not a directory" >&2; exit 1; }

# Exact Mesa software-GL closure as bundled by bundle-dist.sh. Versioned
# sonames (libgallium embeds the Mesa version, libLLVM the LLVM major) must be
# bumped with the build image's Mesa/LLVM. libgallium is dlopen'd by
# libEGL/libGL (never DT_NEEDED), so the consumer's newer apk soname is
# invisible to the ldd gate below. Everything else in the bundle is WebKit's
# own set or universal-runtime libs and stays.
MESA_CLOSURE="
libLLVM.so.22.1
libgallium-26.1.1.so
libSPIRV-Tools.so
libEGL.so.1
libGL.so.1
libgbm.so.1
libdrm.so.2
libdrm_amdgpu.so.1
libdrm_intel.so.1
libelf.so.1
libxcb.so.1
libxcb-dri3.so.0
libxcb-glx.so.0
libxcb-present.so.0
libxcb-randr.so.0
libxcb-shm.so.0
libxcb-sync.so.1
libxcb-xfixes.so.0
libX11.so.6
libX11-xcb.so.1
libXau.so.6
libXdmcp.so.6
libXext.so.6
libXi.so.6
libXxf86vm.so.1
libxshmfence.so.1
"

removed=0
for f in $MESA_CLOSURE; do
  if [ -f "$DST/$f" ]; then
    rm -f "$DST/$f"
    removed=$((removed + 1))
  fi
done
echo "strip-mesa-closure: removed $removed Mesa-closure libs from $(basename "$DST")"

# Gate: every remaining ELF in the bundle must resolve against the consumer's
# libs (RPATH=$ORIGIN + default /usr/lib, where the apk Mesa now lives) —
# mirrors bundle-dist.sh's own post-bundle check.
missing=0
for f in "$DST"/*; do
  [ -f "$f" ] || continue
  [ "$(head -c 4 "$f" 2>/dev/null || true)" = "$(printf '\177ELF')" ] || continue
  notfound=$(ldd "$f" 2>&1 | grep -c 'not found' || true)
  if [ "$notfound" -gt 0 ]; then
    echo "ERROR: $(basename "$f") has $notfound unresolved deps after Mesa strip:" >&2
    ldd "$f" 2>&1 | grep 'not found' >&2
    missing=$((missing + notfound))
  fi
done
[ "$missing" -eq 0 ] || { echo "strip-mesa-closure: FAILED with $missing unresolved dep(s)" >&2; exit 1; }
echo "strip-mesa-closure: all remaining ELFs resolve against consumer libs"
