#!/usr/bin/env bash
# Make a staged WebKit MiniBrowser dist self-contained:
#   - copy transitive system .so deps into <dist>/ (excluding universal-runtime
#     libs that MUST resolve from the consumer's base)
#   - patchelf RPATH=$ORIGIN on both MiniBrowser + every bundled .so (flat layout)
# Result: artifact runs on any musl base regardless of system lib version drift.
#
# Usage: bundle-dist.sh <port_dir>
# Expects: <port_dir>/MiniBrowser  (built binary, flat layout per PW pw_run.sh)
#          <port_dir>/*.so         (WebKit's primary .so set, alongside binary)
# Mutates <port_dir> in place.
#
# The exclusion list + ldd-walk + patchelf passes mirror firefox/scripts/
# bundle-dist.sh; same musl-ABI rationale (loader+libc must come from the
# consumer's base or dynamic linker state corrupts).

set -euo pipefail

DST="${1:?usage: bundle-dist.sh <port_dir>}"
[ -d "$DST" ] || { echo "bundle-dist: $DST is not a directory" >&2; exit 1; }
[ -x "$DST/MiniBrowser" ] || { echo "bundle-dist: $DST/MiniBrowser is not executable" >&2; exit 1; }

echo "===== Bundling .so deps + patchelf RPATH for $(basename "$DST") ====="

EXCLUDE_LIBS="ld-musl-x86_64.so.1 libc.musl-x86_64.so.1 libgcc_s.so.1 libstdc++.so.6"

ldd_walk() {
  local target="$1"
  [ -e "$target" ] || return 0
  for so in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/' || true); do
    base=$(basename "$so")
    case " $EXCLUDE_LIBS " in *" $base "*) continue ;; esac
    [ -f "$so" ] && [ ! -f "$DST/$base" ] && cp -aL "$so" "$DST/" || true
  done
}

ldd_walk "$DST/MiniBrowser"
for so in "$DST"/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done
for so in "$DST"/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done
for so in "$DST"/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done

# Flat layout: MiniBrowser + libs side-by-side → RPATH=$ORIGIN for everything.
patchelf --set-rpath '$ORIGIN' "$DST/MiniBrowser" 2>/dev/null || true
for so in "$DST"/*.so*; do
  [ -L "$so" ] && continue
  patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
done

missing=$(ldd "$DST/MiniBrowser" 2>/dev/null | grep 'not found' || true)
if [ -n "$missing" ]; then
  echo "ERROR: $DST/MiniBrowser still has unresolved deps after bundle:" >&2
  echo "$missing" >&2
  echo "---ldd full output:" >&2
  ldd "$DST/MiniBrowser" 2>&1 | head -40 >&2
  exit 1
fi
echo "===== Self-contained $(basename "$DST"): $(du -sh "$DST" | cut -f1) ====="
