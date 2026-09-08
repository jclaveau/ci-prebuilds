#!/bin/sh
# Builds and runs zen-probe.c, and refuses a run where the platform arm never
# reached libc — gcc folds fmod on some divisors and a vacuous arm reports a
# plausible number (see fmod-call-counter.c).
set -eu
here="$(dirname "$0")"
cc="${CC:-gcc}"
out="${TMPDIR:-/tmp}/zen-probe"
rm -rf "$out"; mkdir -p "$out"

$cc -O2 -fno-builtin-fmod -o "$out/probe" "$here/zen-probe.c" -lm
$cc -O2 -fPIC -shared -o "$out/libcounter.so" "$here/../fmod-call-counter.c" -ldl

echo "===== non-vacuity: the platform arm must reach libc ====="
# 5 timing rounds x 8,999,999 calls on the libc arm alone.
MIN=44000000
FMOD_COUNT_OUT="$out/count" LD_PRELOAD="$out/libcounter.so" "$out/probe" >/dev/null
CALLS=$(cat "$out"/count.* 2>/dev/null || echo 0)
echo "libc fmod calls observed: $CALLS (minimum $MIN)"
[ "$CALLS" -ge "$MIN" ] || { echo "FAIL: libc fmod was folded away" >&2; exit 1; }

echo "===== measurement (uninstrumented) ====="
"$out/probe" | tee "$out/report.txt"
grep -q 'MISMATCH' "$out/report.txt" && { echo "FAIL: a candidate is not bit-exact" >&2; exit 1; }
exit 0
