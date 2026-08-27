#!/bin/sh
# Proves libfastfmod.so returns bit-identical results to musl's own fmod.
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
# Usage: run-gate.sh [srcdir] [outdir]
set -eu

SRC="${1:-$(dirname "$0")}"
OUT="${2:-/tmp/fastfmod-gate}"
CC="${CC:-gcc}"
# The vectors binary makes exactly 7,501,023 fmod calls in its
# verification classes; the counter run skips the timing loop, so this
# floor sits just under that and any inlining drops it to ~0.
MIN_CALLS=7500000

rm -rf "$OUT"
mkdir -p "$OUT"

echo "===== build ====="
# -fno-builtin-fmod on the vectors binary is load-bearing; see the file header.
$CC -O2 -fno-builtin-fmod -o "$OUT/vectors" "$SRC/fastfmod-vectors.c" -lm
$CC -O2 -fPIC -shared -o "$OUT/libfastfmod.so" "$SRC/fastfmod.c"
$CC -O2 -fPIC -shared -o "$OUT/libcounter.so" "$SRC/fmod-call-counter.c" -ldl
# The corrupted twin: the cmov's two arms swapped. Derived from the same
# source so it cannot drift away from the real one, and it must fail step 5.
sed 's/i = (r >> 63) ? i : r;/i = (r >> 63) ? r : i;/' "$SRC/fastfmod.c" > "$OUT/broken.c"
if cmp -s "$SRC/fastfmod.c" "$OUT/broken.c"; then
  echo "FAIL: the corruption did not apply — the negative control would be vacuous" >&2
  exit 1
fi
$CC -O2 -fPIC -shared -o "$OUT/libbroken.so" "$OUT/broken.c"

echo "===== 1. non-vacuity: fmod must really be called ====="
rm -f "$OUT"/count.*
FMOD_COUNT_OUT="$OUT/count" LD_PRELOAD="$OUT/libcounter.so" "$OUT/vectors" >/dev/null 2>&1
CALLS=$(cat "$OUT"/count.* 2>/dev/null || echo 0)
echo "libc fmod calls observed: $CALLS (minimum $MIN_CALLS)"
if [ "$CALLS" -lt "$MIN_CALLS" ]; then
  echo "FAIL: fmod was inlined away — this run verifies nothing" >&2
  exit 1
fi

echo "===== 2. reference run (musl) ====="
FASTFMOD_TIMING=1 "$OUT/vectors" > "$OUT/reference.txt" 2> "$OUT/reference.time"
echo "$(head -1 "$OUT/reference.txt")  $(cat "$OUT/reference.time")"

echo "===== 3. subject run (libfastfmod.so preloaded) ====="
# ld.so only warns on an unloadable preload, so prove it loaded rather than
# trusting the variable: the process must map it.
LD_PRELOAD="$OUT/libfastfmod.so" sh -c 'grep -q libfastfmod /proc/self/maps' \
  || { echo "FAIL: libfastfmod.so did not load" >&2; exit 1; }
FASTFMOD_TIMING=1 LD_PRELOAD="$OUT/libfastfmod.so" "$OUT/vectors" > "$OUT/subject.txt" 2> "$OUT/subject.time"
echo "$(head -1 "$OUT/subject.txt")  $(cat "$OUT/subject.time")"

echo "===== 4. bit-exactness ====="
if ! diff -u "$OUT/reference.txt" "$OUT/subject.txt" > "$OUT/diff.txt"; then
  echo "FAIL: libfastfmod.so is not bit-identical to musl's fmod" >&2
  head -40 "$OUT/diff.txt" >&2
  exit 1
fi
echo "PASS: $(head -1 "$OUT/subject.txt") comparisons, all 64 bucket digests identical"

echo "===== 5. negative control: the gate must reject a broken build ====="
# Bounded: a corrupted fmod can spin forever rather than answer wrongly (this
# one does — the normalisation loop shifts a zeroed significand for ever), and
# a hang is a rejection too, just one that has to be caught rather than waited
# on. Only byte-identical output means the comparison has no teeth.
: > "$OUT/broken.txt"
# `|| BROKEN_RC=$?` rather than a bare call then `$?`: under `set -e` the
# non-zero exit aborts the script before the assignment is ever reached, and
# the gate then fails with the control's own rc instead of judging it.
BROKEN_RC=0
timeout 90 env LD_PRELOAD="$OUT/libbroken.so" "$OUT/vectors" \
  > "$OUT/broken.txt" 2>/dev/null || BROKEN_RC=$?
if [ "$BROKEN_RC" -eq 124 ] || [ "$BROKEN_RC" -eq 137 ]; then
  echo "PASS: corrupted build did not terminate — rejected"
elif diff -q "$OUT/reference.txt" "$OUT/broken.txt" >/dev/null 2>&1; then
  echo "FAIL: a deliberately corrupted fmod passed — this gate proves nothing" >&2
  exit 1
else
  echo "PASS: corrupted build produced different digests — rejected"
fi

echo "===== gate green ====="
