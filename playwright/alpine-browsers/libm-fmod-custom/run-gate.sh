#!/bin/sh
# Proves libm-fmod-custom.c and libm-fmodf-custom.c return bit-identical results
# to musl's own fmod and fmodf,
# in both forms the browsers ship: the .so WebKit preloads, and (when ASM_CC
# names a clang) gcc's assembly assembled by clang, as Firefox links it.
#
# Method: build ONE vectors binary, run it twice — plain, then with the
# preload — and diff the outputs. The reference is therefore musl itself
# rather than a second implementation of mine, and the subject is the actual
# shipped .so rather than the same code linked differently.
#
# Three things this gate refuses to accept:
#   1. a run where fmod was never actually called (gcc inlines it on a
#      power-of-two divisor, and then everything passes vacuously);
#   2. a preloaded run that did not load the preload (ld.so only WARNS on a
#      missing preload and carries on, which would silently compare musl
#      against musl and pass);
#   3. itself, unless a deliberately corrupted build makes it fail.
#
# Usage: [ASM_CC=clang-23] run-gate.sh [srcdir] [outdir]
set -eu

SRC="${1:-$(dirname "$0")}"
OUT="${2:-/tmp/libm-fmod-custom-gate}"
CC="${CC:-gcc}"
# The vectors binary makes exactly 7,501,023 fmod calls in its
# verification classes; the counter run skips the timing loop, so this
# floor sits just under that and any inlining drops it to ~0.
MIN_CALLS=7500000
# Same for fmodf: classes 6-9 make 4,001,156 calls.
MIN_FMODF_CALLS=4000000

rm -rf "$OUT"
mkdir -p "$OUT"

echo "===== build ====="
# -fno-builtin-fmod on the vectors binary is load-bearing; see the file header.
$CC -O2 -fno-builtin-fmod -fno-builtin-fmodf -o "$OUT/vectors" "$SRC/libm-fmod-custom-vectors.c" -lm
$CC -O2 -fPIC -shared -o "$OUT/libm-fmod-custom.so" "$SRC/libm-fmod-custom.c" \
  "$SRC/libm-fmodf-custom.c"
$CC -O2 -fPIC -shared -o "$OUT/libcounter.so" "$SRC/fmod-call-counter.c" -ldl
if [ -n "${ASM_CC:-}" ]; then
  # Firefox's form. libxul builds it with -fvisibility=hidden, left out here
  # so the preload can still interpose; the function body is the same.
  $CC -O2 -fPIC -S -o "$OUT/libm-fmod-custom.s" "$SRC/libm-fmod-custom.c"
  $ASM_CC -c -fPIC -o "$OUT/libm-fmod-custom-asm.o" "$OUT/libm-fmod-custom.s"
  # chromium has no Firefox form: fmodf rides in the gcc-built preload only, so
  # 4b's fmodf is musl's and its digests must still match.
  $CC -shared -o "$OUT/libm-fmod-custom-asm.so" "$OUT/libm-fmod-custom-asm.o"
fi
# The corrupted twin: every reduction divides by the wrong modulus — fmod's
# single-divide fast path and general path, fmodf's 32-bit and 64-bit fast
# paths and its general path. Derived from the same source so it cannot
# drift away from the real one, and it must fail step 5.
#
# These seds are COUPLED to the source's shape, deliberately. When a loop was
# rewritten and a previous sed matched nothing, this gate refused to run —
# which is the behaviour to keep. A negative control that corrupts nothing is
# worse than none, so each corruption must be present in broken.c.
sed -e 's|r_fast = mx_fast % (my_fast >> d_fast);|r_fast = mx_fast % (my_fast >> (d_fast + 1));|' \
    -e 's|mx = (mx << ls) % my;|mx = (mx << (ls + 1)) % my;|' \
  "$SRC/libm-fmod-custom.c" > "$OUT/broken.c"
sed -e 's|r_fast = mx_fast % (my_fast >> d_fast);|r_fast = mx_fast % (my_fast >> (d_fast + 1));|' \
    -e 's|r_mid = (uint32_t)((mx24 << d_fast) % my24);|r_mid = (uint32_t)((mx24 << d_fast) % (my24 + 1));|' \
    -e 's|mx = (mx << 40) % my;|mx = (mx << 40) % (my + 1);|' \
  "$SRC/libm-fmodf-custom.c" > "$OUT/brokenf.c"
if ! grep -qF 'my_fast >> (d_fast + 1)' "$OUT/broken.c" \
   || ! grep -qF 'mx << (ls + 1)' "$OUT/broken.c" \
   || ! grep -qF 'my_fast >> (d_fast + 1)' "$OUT/brokenf.c" \
   || ! grep -qF '% (my24 + 1)' "$OUT/brokenf.c" \
   || ! grep -qF '% (my + 1)' "$OUT/brokenf.c"; then
  echo "FAIL: a corruption did not apply — the negative control would be vacuous" >&2
  exit 1
fi
# Two twins, so a sound fmod cannot hide a broken fmodf or the reverse.
$CC -O2 -fPIC -shared -o "$OUT/libbroken.so" "$OUT/broken.c" "$SRC/libm-fmodf-custom.c"
$CC -O2 -fPIC -shared -o "$OUT/libbrokenf.so" "$SRC/libm-fmod-custom.c" "$OUT/brokenf.c"

echo "===== 1. non-vacuity: fmod must really be called ====="
rm -f "$OUT"/count.*
FMOD_COUNT_OUT="$OUT/count" LD_PRELOAD="$OUT/libcounter.so" "$OUT/vectors" >/dev/null 2>&1
read -r CALLS FMODF_CALLS < "$(ls "$OUT"/count.* | head -1)" || true
CALLS=${CALLS:-0}
FMODF_CALLS=${FMODF_CALLS:-0}
echo "libc fmod calls observed: $CALLS (minimum $MIN_CALLS)"
echo "libc fmodf calls observed: $FMODF_CALLS (minimum $MIN_FMODF_CALLS)"
if [ "$CALLS" -lt "$MIN_CALLS" ] || [ "$FMODF_CALLS" -lt "$MIN_FMODF_CALLS" ]; then
  echo "FAIL: fmod or fmodf was inlined away — this run verifies nothing" >&2
  exit 1
fi

echo "===== 2. reference run (musl) ====="
LIBM_FMOD_CUSTOM_TIMING=1 "$OUT/vectors" > "$OUT/reference.txt" 2> "$OUT/reference.time"
echo "$(head -1 "$OUT/reference.txt")  $(cat "$OUT/reference.time")"

echo "===== 3. subject run (libm-fmod-custom.so preloaded) ====="
# ld.so only warns on an unloadable preload, so prove it loaded rather than
# trusting the variable: the process must map it.
LD_PRELOAD="$OUT/libm-fmod-custom.so" sh -c 'grep -q libm-fmod-custom /proc/self/maps' \
  || { echo "FAIL: libm-fmod-custom.so did not load" >&2; exit 1; }
LIBM_FMOD_CUSTOM_TIMING=1 LD_PRELOAD="$OUT/libm-fmod-custom.so" "$OUT/vectors" > "$OUT/subject.txt" 2> "$OUT/subject.time"
echo "$(head -1 "$OUT/subject.txt")  $(cat "$OUT/subject.time")"

echo "===== 4. bit-exactness ====="
if ! diff -u "$OUT/reference.txt" "$OUT/subject.txt" > "$OUT/diff.txt"; then
  echo "FAIL: libm-fmod-custom.so is not bit-identical to musl's fmod/fmodf" >&2
  head -40 "$OUT/diff.txt" >&2
  exit 1
fi
echo "PASS: $(head -1 "$OUT/subject.txt") comparisons, all 64 bucket digests identical"

if [ -n "${ASM_CC:-}" ]; then
  echo "===== 4b. Firefox form: gcc assembly assembled by $ASM_CC ====="
  LD_PRELOAD="$OUT/libm-fmod-custom-asm.so" sh -c 'grep -q libm-fmod-custom-asm /proc/self/maps' \
    || { echo "FAIL: libm-fmod-custom-asm.so did not load" >&2; exit 1; }
  LD_PRELOAD="$OUT/libm-fmod-custom-asm.so" "$OUT/vectors" > "$OUT/subject-asm.txt"
  if ! diff -u "$OUT/reference.txt" "$OUT/subject-asm.txt" > "$OUT/diff-asm.txt"; then
    echo "FAIL: the Firefox form is not bit-identical to musl's fmod" >&2
    head -40 "$OUT/diff-asm.txt" >&2
    exit 1
  fi
  echo "PASS: Firefox form, all 64 bucket digests identical"
fi

echo "===== 5. negative control: the gate must reject a broken build ====="
# Bounded: a corrupted fmod can spin forever rather than answer wrongly (this
# one does — the normalisation loop shifts a zeroed significand for ever), and
# a hang is a rejection too, just one that has to be caught rather than waited
# on. Only byte-identical output means the comparison has no teeth.
for twin in libbroken libbrokenf; do
  : > "$OUT/$twin.txt"
  # `|| BROKEN_RC=$?` rather than a bare call then `$?`: under `set -e` the
  # non-zero exit aborts the script before the assignment is ever reached, and
  # the gate then fails with the control's own rc instead of judging it.
  BROKEN_RC=0
  timeout 90 env LD_PRELOAD="$OUT/$twin.so" "$OUT/vectors" \
    > "$OUT/$twin.txt" 2>/dev/null || BROKEN_RC=$?
  if [ "$BROKEN_RC" -eq 124 ] || [ "$BROKEN_RC" -eq 137 ]; then
    echo "PASS: $twin did not terminate — rejected"
  elif diff -q "$OUT/reference.txt" "$OUT/$twin.txt" >/dev/null 2>&1; then
    echo "FAIL: $twin, a deliberately corrupted build, passed — this gate proves nothing" >&2
    exit 1
  else
    echo "PASS: $twin produced different digests — rejected"
  fi
done

echo "===== gate green ====="
