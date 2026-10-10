#!/bin/sh
# Runs musl's own libc-test math cases against libm-fmod-custom, in both
# shipped forms, as an independent oracle beside run-gate.sh.
#
# run-gate.sh compares against musl, so it cannot catch a bug musl shares.
# libc-test's tables (sanity, special, ucb) carry the EXPECTED results and the
# expected floating-point exceptions, so this also checks what run-gate.sh
# never looks at: fmod(inf, y) and fmod(x, 0) must raise FE_INVALID.
#
# Every function the .so defines is tested: fmod always, fmodf once the .so
# carries it. Each one also gets two corrupted twins that must FAIL, one with a
# wrong remainder and one returning NaN without raising FE_INVALID, so a
# libc-test that checks nothing cannot pass here.
#
# Usage: [ASM_CC=clang-23] run-libc-test.sh [srcdir] [outdir]
set -eu

SRC="${1:-$(dirname "$0")}"
OUT="${2:-/tmp/libm-fmod-custom-libc-test}"
CC="${CC:-gcc}"
LIBC_TEST_REPO=https://repo.or.cz/libc-test.git
LIBC_TEST_REV=7b95dfa5f5d5ca4d949221e0228ccc290bacc14e

rm -rf "$OUT"
mkdir -p "$OUT"

echo "===== libc-test ${LIBC_TEST_REV} ====="
git init -q "$OUT/libc-test"
# repo.or.cz resets connections now and then (gate runs 38045295867 and
# 38051815857: "curl 35 Recv failure"); the rev is pinned, so a retry is safe.
fetch_attempt=1
until git -C "$OUT/libc-test" fetch -q --depth 1 "$LIBC_TEST_REPO" "$LIBC_TEST_REV"; do
  if [ "$fetch_attempt" -ge 4 ]; then
    echo "FAIL: could not fetch libc-test from $LIBC_TEST_REPO" >&2
    exit 1
  fi
  sleep $((fetch_attempt * 15))
  fetch_attempt=$((fetch_attempt + 1))
done
git -C "$OUT/libc-test" checkout -q FETCH_HEAD
LT="$OUT/libc-test"

echo "===== build ====="
SOURCES="$SRC/libm-fmod-custom.c"
if [ -f "$SRC/libm-fmodf-custom.c" ]; then
  SOURCES="$SOURCES $SRC/libm-fmodf-custom.c"
fi
# shellcheck disable=SC2086
$CC -O2 -fPIC -shared -o "$OUT/libm-fmod-custom.so" $SOURCES
FUNCTIONS=fmod
if nm -D --defined-only "$OUT/libm-fmod-custom.so" | grep -qw fmodf; then
  FUNCTIONS="fmod fmodf"
fi
echo "functions under test: $FUNCTIONS"

# -fno-builtin keeps every call a real libm call; the import check below
# proves it rather than trusting the flag.
for fn in $FUNCTIONS; do
  $CC -std=c99 -D_POSIX_C_SOURCE=200809L -O0 -fno-builtin -frounding-math \
    -I"$LT/src/common" -I"$LT/src/math" -o "$OUT/test-$fn" \
    "$LT/src/math/$fn.c" "$LT/src/common/mtest.c" "$LT/src/common/print.c" -lm
  if ! nm -D "$OUT/test-$fn" | grep -qE "^ +U $fn\$"; then
    echo "FAIL: test-$fn does not import $fn — it would test nothing" >&2
    exit 1
  fi
done

if [ -n "${ASM_CC:-}" ]; then
  # Firefox's form, as in run-gate.sh: gcc's assembly assembled by clang.
  ASM_OBJECTS=
  for src in $SOURCES; do
    base=$(basename "$src" .c)
    $CC -O2 -fPIC -S -o "$OUT/$base.s" "$src"
    asm_flags=
    if [ "$base" = libm-fmodf-custom ]; then
      asm_flags=-mbranches-within-32B-boundaries
    fi
    # shellcheck disable=SC2086
    $ASM_CC -c -fPIC $asm_flags -o "$OUT/$base-asm.o" "$OUT/$base.s"
    ASM_OBJECTS="$ASM_OBJECTS $OUT/$base-asm.o"
  done
  # shellcheck disable=SC2086
  $CC -shared -o "$OUT/libm-fmod-custom-asm.so" $ASM_OBJECTS
fi

# The corrupted twins. Coupled to the source's shape on purpose: a sed that
# matches nothing stops the script instead of leaving a control that corrupts
# nothing.
corrupt() {
  src="$1" dst="$2" old="$3" new="$4"
  sed -e "s|$old|$new|" "$src" > "$dst"
  if cmp -s "$src" "$dst"; then
    echo "FAIL: corruption of $(basename "$src") did not apply — the control would be vacuous" >&2
    exit 1
  fi
}
corrupt "$SRC/libm-fmod-custom.c" "$OUT/value-fmod.c" \
  'r_fast = mx_fast % (my_fast >> d_fast);' 'r_fast = mx_fast % (my_fast >> (d_fast + 1));'
corrupt "$SRC/libm-fmod-custom.c" "$OUT/invalid-fmod.c" \
  'return (x \* y) / (x \* y);' 'return __builtin_nan("");'
$CC -O2 -fPIC -shared -o "$OUT/value-fmod.so" "$OUT/value-fmod.c"
$CC -O2 -fPIC -shared -o "$OUT/invalid-fmod.so" "$OUT/invalid-fmod.c"
if [ -f "$SRC/libm-fmodf-custom.c" ]; then
  # The d <= 8 path alone; a second value twin breaks the d <= 40 path that
  # libc-test's cases also reach, so the control is not one path deep.
  corrupt "$SRC/libm-fmodf-custom.c" "$OUT/value-fmodf.c" \
    'r_fast = mx_fast % (my_fast >> d_fast);' 'r_fast = mx_fast % (my_fast >> (d_fast + 1));'
  corrupt "$SRC/libm-fmodf-custom.c" "$OUT/value_mid-fmodf.c" \
    'r_mid = (uint32_t)((mx24 << d_fast) % my24);' 'r_mid = (uint32_t)((mx24 << d_fast) % (my24 + 1));'
  corrupt "$SRC/libm-fmodf-custom.c" "$OUT/invalid-fmodf.c" \
    'return (x \* y) / (x \* y);' 'return __builtin_nanf("");'
  $CC -O2 -fPIC -shared -o "$OUT/value-fmodf.so" "$OUT/value-fmodf.c"
  $CC -O2 -fPIC -shared -o "$OUT/value_mid-fmodf.so" "$OUT/value_mid-fmodf.c"
  $CC -O2 -fPIC -shared -o "$OUT/invalid-fmodf.so" "$OUT/invalid-fmodf.c"
fi

# ld.so only warns on an unloadable preload, so each run first proves the
# library is mapped.
run_with() {
  fn="$1" preload="$2"
  LD_PRELOAD="$preload" sh -c "grep -qF '$preload' /proc/self/maps" \
    || { echo "FAIL: $preload did not load" >&2; exit 1; }
  LD_PRELOAD="$preload" "$OUT/test-$fn"
}

echo "===== 1. reference: musl itself must pass ====="
for fn in $FUNCTIONS; do
  "$OUT/test-$fn"
  echo "PASS: $fn, musl"
done

echo "===== 2. subject: libm-fmod-custom.so ====="
for fn in $FUNCTIONS; do
  run_with "$fn" "$OUT/libm-fmod-custom.so"
  echo "PASS: $fn, libm-fmod-custom.so"
done

if [ -n "${ASM_CC:-}" ]; then
  echo "===== 2b. Firefox form: gcc assembly assembled by $ASM_CC ====="
  for fn in $FUNCTIONS; do
    run_with "$fn" "$OUT/libm-fmod-custom-asm.so"
    echo "PASS: $fn, Firefox form"
  done
fi

echo "===== 3. negative controls: libc-test must reject each corruption ====="
for fn in $FUNCTIONS; do
  kinds="value invalid"
  if [ "$fn" = fmodf ]; then
    kinds="value value_mid invalid"
  fi
  for kind in $kinds; do
    if run_with "$fn" "$OUT/$kind-$fn.so" > "$OUT/$kind-$fn.txt" 2>&1; then
      echo "FAIL: libc-test passed a $kind-corrupted $fn — it checks nothing" >&2
      exit 1
    fi
    echo "PASS: $kind-corrupted $fn rejected ($(grep -c . "$OUT/$kind-$fn.txt") failing lines)"
  done
done

echo "===== libc-test green ====="
