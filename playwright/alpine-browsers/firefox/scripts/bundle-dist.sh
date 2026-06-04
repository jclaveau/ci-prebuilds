#!/usr/bin/env bash
# Make the staged FF dist tree at $DST self-contained:
#   - copy transitive system .so deps into $DST (excluding universal-runtime
#     libs that MUST resolve from the consumer's base)
#   - patchelf RPATH=$ORIGIN on every binary + top-level .so
#   - bundle the ICU data file (Alpine's libicudata.so.{ver} is a stub)
# Result: a fully self-contained artifact that works on any musl base
# regardless of ICU/NSPR/NSS/etc version drift.
#
# Both the cold-build (apply-and-build.sh) and iter (apply-and-build-iter.sh)
# entrypoints source this so the iter path also produces a correctly-bundled
# artifact.
#
# Usage: bundle-dist.sh <dist_dir>
# Expects: <dist_dir>/firefox (built binary)
# Mutates <dist_dir> in place.

set -euo pipefail

DST="${1:?usage: bundle-dist.sh <dist_dir>}"
[ -d "$DST" ] || { echo "bundle-dist: $DST is not a directory" >&2; exit 1; }
[ -x "$DST/firefox" ] || { echo "bundle-dist: $DST/firefox is not executable" >&2; exit 1; }

echo "===== Bundling .so deps + patchelf RPATH=\$ORIGIN ====="
FF_BINS="$DST/firefox $DST/firefox-bin $DST/glxtest $DST/vaapitest $DST/pingsender"

# Universal-runtime libs that MUST resolve from the consumer's base, not the
# bundle. The binary's ELF interpreter is hardcoded to the system loader
# (/lib/ld-musl-x86_64.so.1) — patchelf --set-interpreter can't be relative —
# so the loader+libc ABI is fixed by the consumer's musl version. If we bundle
# our build-time copies, peer .so files resolve them via RPATH=$ORIGIN and end
# up calling a different libc than the loader, which corrupts dynamic linker
# state and segfaults at XPCOM init when the consumer base's musl version
# diverges from the builder's (e.g. consumer alpine 3.21 musl 1.2.5-r11 vs
# builder alpine:edge musl 1.2.6-r0). Skip and let the system loader pick up
# the consumer's matching copies via default search paths.
# - ld-musl-x86_64.so.1: musl loader/libc. Same file as libc.musl-x86_64.so.1.
# - libgcc_s.so.1, libstdc++.so.6: GCC runtime/C++ stdlib. Tracks the system
#   toolchain; bundling a foreign-version copy breaks libc-coupled symbols
#   (__cxa_thread_atexit_impl etc).
EXCLUDE_LIBS="ld-musl-x86_64.so.1 libc.musl-x86_64.so.1 libgcc_s.so.1 libstdc++.so.6"

# Walk ldd on a target, copy system .so deps into $DST (top level only —
# nested gmp-clearkey/ etc. dlopen explicitly and inherit firefox's RPATH).
ldd_walk() {
  local target="$1"
  [ -e "$target" ] || return 0
  for so in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/' || true); do
    base=$(basename "$so")
    case " $EXCLUDE_LIBS " in *" $base "*) continue ;; esac
    [ -f "$so" ] && [ ! -f "$DST/$base" ] && cp -aL "$so" "$DST"/ || true
  done
}

# Pass 1: walk binaries + already-bundled .so files.
for t in $FF_BINS; do ldd_walk "$t"; done
for so in "$DST"/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done
# Pass 2: deps-of-deps for second-order resolution (libicui18n -> libicuuc, etc.)
for so in "$DST"/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done
# Pass 3: rare third-order (libstdc++ -> libgcc_s, etc.)
for so in "$DST"/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done

# Patchelf RPATH=$ORIGIN on every binary + top-level .so. The loader uses
# RPATH of the LOADING module, so libxul.so needs $ORIGIN to find peer libs
# in the same dir.
for t in $FF_BINS; do
  [ -f "$t" ] && patchelf --set-rpath '$ORIGIN' "$t" 2>/dev/null || true
done
for so in "$DST"/*.so*; do
  [ -L "$so" ] && continue
  patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
done

# ICU data file. aports builds firefox with --with-system-icu, and Alpine's
# libicudata.so.78 is a 12 KB stub — the actual locale data ships separately
# as /usr/share/icu/${ver}/icudt${maj}l.dat in the icu-data-full apk. At
# runtime libicuuc stats that absolute path; on a consumer base with a
# different ICU major (alpine 3.21 has ICU 76, builder edge has 78) the stat
# returns ENOENT and the load deref's null → SEGV at XPCOM init. Bundle the
# data file next to the .so files; the consumer image sets
# ICU_DATA=<bundle dir> so libicuuc finds it without the absolute path.
ICU_VER=$(ls /usr/share/icu/ 2>/dev/null | head -1)
if [ -n "$ICU_VER" ]; then
  ICU_DAT=$(ls /usr/share/icu/"$ICU_VER"/icudt*l.dat 2>/dev/null | head -1)
  if [ -f "$ICU_DAT" ]; then
    cp -aL "$ICU_DAT" "$DST"/
    echo "===== Bundled ICU data: $(basename "$ICU_DAT") (icu $ICU_VER) ====="
  else
    echo "WARN: /usr/share/icu/$ICU_VER/icudt*l.dat not found; consumer may segfault at XPCOM init" >&2
  fi
else
  echo "WARN: no ICU data dir under /usr/share/icu/ on builder" >&2
fi

# Sanity check: no "not found" in libxul ldd. Fail loud at producer time,
# not silently at consumer runtime. (firefox-bin is small; libxul.so is the
# fat one and most likely to surface missing deps.)
missing=$(ldd "$DST/libxul.so" 2>/dev/null | grep 'not found' || true)
if [ -n "$missing" ]; then
  echo "ERROR: libxul.so still has unresolved deps after bundle:" >&2
  echo "$missing" >&2
  echo "---firefox binary ldd:" >&2
  ldd "$DST/firefox" 2>&1 | head -30 >&2
  exit 1
fi
echo "===== Self-contained artifact: $(du -sh "$DST" | cut -f1) ====="
