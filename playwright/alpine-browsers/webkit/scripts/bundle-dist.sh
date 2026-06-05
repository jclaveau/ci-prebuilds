#!/usr/bin/env bash
# Make a staged WebKit MiniBrowser dist self-contained:
#   - copy transitive system .so deps into <dist>/lib (excluding universal-runtime
#     libs that MUST resolve from the consumer's base)
#   - patchelf RPATH=$ORIGIN/../lib on bin/MiniBrowser + RPATH=$ORIGIN on every
#     bundled .so
# Result: artifact runs on any musl base regardless of system lib version drift.
#
# Usage: bundle-dist.sh <port_dir>
# Expects: <port_dir>/bin/MiniBrowser (built binary)
#          <port_dir>/lib/            (WebKit's primary .so set)
# Mutates <port_dir> in place.
#
# The exclusion list + ldd-walk + patchelf passes mirror firefox/scripts/
# bundle-dist.sh; same musl-ABI rationale (loader+libc must come from the
# consumer's base or dynamic linker state corrupts).

set -euo pipefail

DST="${1:?usage: bundle-dist.sh <port_dir>}"
[ -d "$DST" ] || { echo "bundle-dist: $DST is not a directory" >&2; exit 1; }
[ -x "$DST/bin/MiniBrowser" ] || { echo "bundle-dist: $DST/bin/MiniBrowser is not executable" >&2; exit 1; }

echo "===== Bundling .so deps + patchelf RPATH for $(basename "$DST") ====="

# Same exclusion rationale as firefox bundle-dist: loader + libc + GCC runtime
# must resolve from the consumer's base, not the bundle. patchelf cannot make
# the ELF interpreter relative, so libc-ABI is fixed by the consumer's musl;
# bundling build-time copies of these breaks the dynamic linker.
EXCLUDE_LIBS="ld-musl-x86_64.so.1 libc.musl-x86_64.so.1 libgcc_s.so.1 libstdc++.so.6"

ldd_walk() {
  local target="$1"
  [ -e "$target" ] || return 0
  for so in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/' || true); do
    base=$(basename "$so")
    case " $EXCLUDE_LIBS " in *" $base "*) continue ;; esac
    [ -f "$so" ] && [ ! -f "$DST/lib/$base" ] && cp -aL "$so" "$DST/lib/" || true
  done
}

# Pass 1: walk MiniBrowser + already-bundled .so set.
ldd_walk "$DST/bin/MiniBrowser"
for so in "$DST"/lib/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done
# Pass 2-3: deps-of-deps for second/third-order resolution.
for so in "$DST"/lib/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done
for so in "$DST"/lib/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done

# Patchelf:
# - MiniBrowser lives at <dist>/bin/, libs at <dist>/lib/ → RPATH=$ORIGIN/../lib
# - bundled .so files load their peers in the same dir → RPATH=$ORIGIN
patchelf --set-rpath '$ORIGIN/../lib' "$DST/bin/MiniBrowser" 2>/dev/null || true
for so in "$DST"/lib/*.so*; do
  [ -L "$so" ] && continue
  patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
done

# Sanity check: no "not found" against MiniBrowser. Fail loud at producer time,
# not silently at consumer runtime.
missing=$(ldd "$DST/bin/MiniBrowser" 2>/dev/null | grep 'not found' || true)
if [ -n "$missing" ]; then
  echo "ERROR: $DST/bin/MiniBrowser still has unresolved deps after bundle:" >&2
  echo "$missing" >&2
  echo "---ldd full output:" >&2
  ldd "$DST/bin/MiniBrowser" 2>&1 | head -40 >&2
  exit 1
fi
echo "===== Self-contained $(basename "$DST"): $(du -sh "$DST" | cut -f1) ====="
