#!/bin/sh
# Runs libm-fmodf-exhaustive.c: every float x against each divisor in its
# list, the shipped .so's fmodf against the libc's own, bit for bit.
#
# Then the negative control: each corrupted twin, one per reduction path of
# libm-fmodf-custom.c, must show mismatches. The controls run on a single
# divisor, pi * 2^62, whose 2^32 x reach gaps 0..64 and so every path, while
# most x sit below y and cost nothing. Its mantissa must be full: with 2^63,
# one 40-bit loop step leaves mx = 0 and the tail twin passes unseen.
#
# The glibc job sets LIBM_FMOD_CUSTOM_FOLD_NAN=1; see libm-fmodf-exhaustive.c.
#
# Usage: run-fmodf-exhaustive.sh [srcdir] [outdir]
set -eu

SRC="${1:-$(dirname "$0")}"
OUT="${2:-/tmp/libm-fmodf-exhaustive}"
CC="${CC:-gcc}"
CONTROL_DIVISOR=5f490fdb

rm -rf "$OUT"
mkdir -p "$OUT"

echo "===== build ====="
# fmodf compiled as the consumer image compiles it, with its assembler flag.
$CC -O2 -fPIC -Wa,-mbranches-within-32B-boundaries -c -o "$OUT/libm-fmodf-custom.o" \
  "$SRC/libm-fmodf-custom.c"
$CC -O2 -fPIC -shared -o "$OUT/libm-fmod-custom.so" "$SRC/libm-fmod-custom.c" \
  "$OUT/libm-fmodf-custom.o"
# -fno-builtin-fmodf is load-bearing; see the C file's header.
$CC -O2 -fno-builtin-fmodf -pthread -o "$OUT/exhaustive" \
  "$SRC/libm-fmodf-exhaustive.c" -lm -ldl

# Coupled to the source's shape on purpose, as in run-gate.sh: a sed that
# matches nothing stops the script instead of leaving a vacuous control.
TWINS=
twin() {
  name="$1" old="$2" new="$3"
  sed -e "s#$old#$new#" "$SRC/libm-fmodf-custom.c" > "$OUT/$name.c"
  if cmp -s "$SRC/libm-fmodf-custom.c" "$OUT/$name.c"; then
    echo "FAIL: twin $name did not apply — the negative control would be vacuous" >&2
    exit 1
  fi
  $CC -O2 -fPIC -shared -o "$OUT/$name.so" "$OUT/$name.c"
  TWINS="$TWINS $name"
}
twin broken-fmodf-fast \
  'r_fast = mx_fast % (my_fast >> d_fast);' 'r_fast = mx_fast % (my_fast >> (d_fast + 1));'
twin broken-fmodf-mid \
  'r_mid = (uint32_t)((mx24 << d_fast) % my24);' 'r_mid = (uint32_t)((mx24 << d_fast) % (my24 + 1));'
twin broken-fmodf-loop \
  'mx = (mx << 40) % my;' 'mx = (mx << 40) % (my + 1);'
twin broken-fmodf-tail \
  'uint32_t r = (uint32_t)((mx << d) % my);' 'uint32_t r = (uint32_t)((mx << d) % (my + 1));'

echo "===== 1. every x, every listed divisor ====="
"$OUT/exhaustive" "$OUT/libm-fmod-custom.so"
echo "PASS: bit-identical to the libc's fmodf on every x"

echo "===== 2. negative control: each corrupted path must mismatch ====="
for twin in $TWINS; do
  TWIN_RC=0
  "$OUT/exhaustive" "$OUT/$twin.so" "$CONTROL_DIVISOR" > "$OUT/$twin.txt" || TWIN_RC=$?
  if [ "$TWIN_RC" -ne 1 ]; then
    echo "FAIL: $twin, a deliberately corrupted build, was not rejected (rc $TWIN_RC)" >&2
    cat "$OUT/$twin.txt" >&2
    exit 1
  fi
  echo "PASS: $twin rejected — $(head -1 "$OUT/$twin.txt")"
done

echo "===== fmodf exhaustive green ====="
