#!/bin/sh
# Proves libfaststring.so answers memcpy/memmove/memset/memcmp/strlen exactly
# as musl does, on BOTH of its paths.
#
# The shim replaces five routines every process in the image calls millions of
# times, and a wrong byte does not announce itself — it surfaces as a corrupt
# screenshot, a mis-parsed protocol message or a crash somewhere unrelated. So
# the gate refuses four things:
#
#   1. a shim that miscopies (the checks in faststring-test.c);
#   2. itself, unless a deliberately corrupted build makes it fail — a suite
#      that passes on broken code is measuring nothing;
#   3. a preloaded run that did not actually load the preload (ld.so only WARNS
#      on a missing preload and carries on, which would compare musl against
#      musl and pass);
#   4. shipping the no-AVX2 path untested. Every runner this repo can reach has
#      AVX2, so that path would otherwise reach a user's older machine having
#      never executed once. CHS_FAST_STRING=0 forces it here.
#
# Usage: run-gate.sh [srcdir] [outdir]
set -eu

SRC="${1:-$(dirname "$0")}"
OUT="${2:-/tmp/faststring-gate}"
CC="${CC:-gcc}"

# -fno-builtin so the optimizer cannot recognise the byte loops and turn them
# back into calls to the functions being defined; the same flags the image
# builds the shipped .so with.
SHIM_FLAGS="-O2 -fPIC -shared -fno-builtin -fno-tree-loop-distribute-patterns"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "--- building the shim and the checks ---"
# shellcheck disable=SC2086
$CC $SHIM_FLAGS -o "$OUT/libfaststring.so" "$SRC/faststring.c" -ldl
$CC -O2 -o "$OUT/checks" "$SRC/faststring-test.c"

echo "--- AVX2 must not reach the dispatchers ---"
# The translation unit is compiled WITHOUT -mavx2 and only the avx2_* helpers
# carry the target attribute, so a dispatcher containing a ymm register would
# mean the guard can be jumped over — SIGILL on the first copy on a machine
# without AVX2, in every process in the image.
if command -v objdump >/dev/null 2>&1; then
  leaked=$(objdump -d --no-show-raw-insn "$OUT/libfaststring.so" \
    | awk '/^[0-9a-f]+ <(memcpy|memmove|memset|memcmp|strlen)>:/ { inside = 1 }
           /^$/ { inside = 0 }
           inside && /ymm/ { n++ }
           END { print n + 0 }')
  if [ "$leaked" -ne 0 ]; then
    echo "AVX2 leaked into $leaked dispatcher instructions" >&2
    exit 1
  fi
  echo "dispatchers are AVX2-free"
else
  echo "objdump absent — skipping the dispatcher check" >&2
fi

echo "--- control: no preload, must pass ---"
"$OUT/checks"

echo "--- the shim, AVX2 path: must pass, and must prove it loaded ---"
rm -f "$OUT/loaded.txt"
FAST_STRING_MARKER="$OUT/loaded.txt" LD_PRELOAD="$OUT/libfaststring.so" \
  "$OUT/checks"
if [ ! -s "$OUT/loaded.txt" ]; then
  echo "the preload never loaded — the run above compared musl with musl" >&2
  exit 1
fi
echo "loaded by $(wc -l < "$OUT/loaded.txt") process(es)"

echo "--- the shim, musl-fallback path: must pass ---"
CHS_FAST_STRING=0 LD_PRELOAD="$OUT/libfaststring.so" "$OUT/checks"

echo "--- corrupted shim: must fail, or the gate is vacuous ---"
# Flips the last byte of every scalar tail copy. It is a one-byte error at the
# end of a copy, which is the shape a vector loop with a wrong bound produces
# and the shape a weak suite misses.
sed "s|^    d\[i\] = s\[i\];|    d[i] = (unsigned char)(s[i] ^ (i + 1 == n));|" \
    "$SRC/faststring.c" > "$OUT/broken.c"
if diff -q "$OUT/broken.c" "$SRC/faststring.c" >/dev/null; then
  echo "the corruption sed matched nothing — the gate proves nothing" >&2
  exit 1
fi
# shellcheck disable=SC2086
$CC $SHIM_FLAGS -o "$OUT/libbroken.so" "$OUT/broken.c" -ldl
if LD_PRELOAD="$OUT/libbroken.so" "$OUT/checks" >/dev/null 2>&1; then
  echo "the corrupted shim passed — the checks do not cover the copy" >&2
  exit 1
fi
echo "corrupted shim rejected"

echo "faststring gate OK"
