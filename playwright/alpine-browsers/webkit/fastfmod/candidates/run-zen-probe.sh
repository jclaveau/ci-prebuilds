#!/bin/sh
# Builds and runs zen-probe.c, and refuses a run where the platform arm never
# reached libc — gcc folds fmod on some divisors and a vacuous arm reports a
# plausible number (see fmod-call-counter.c).
#
# Two legs on ONE runner: the host (glibc 2.39, the control the browser arm is
# measured against) and alpine:edge (musl, and the gcc that actually compiles
# the shipped libfastfmod.so — codegen for the normalisation loop differs
# between gcc majors, so the ranking has to be read on the shipping one).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="${TMPDIR:-/tmp}/zen-probe"
rm -rf "$out"; mkdir -p "$out"

echo "===== host leg (glibc) ====="
gcc --version | head -1
gcc -O2 -fno-builtin-fmod -o "$out/probe" "$here/zen-probe.c" -lm
gcc -O2 -fPIC -shared -o "$out/libcounter.so" "$here/../fmod-call-counter.c" -ldl

MIN=89000000
FMOD_COUNT_OUT="$out/count" LD_PRELOAD="$out/libcounter.so" "$out/probe" >/dev/null
CALLS=$(cat "$out"/count.* 2>/dev/null || echo 0)
echo "libc fmod calls observed: $CALLS (minimum $MIN)"
[ "$CALLS" -ge "$MIN" ] || { echo "FAIL: libc fmod was folded away" >&2; exit 1; }

"$out/probe" | tee "$out/host.txt"
if grep -q MISMATCH "$out/host.txt"; then
  echo "FAIL: a candidate is not bit-exact" >&2; exit 1
fi

echo
echo "===== alpine leg (musl, shipping gcc) ====="
docker run --rm -v "$here:/src:ro" alpine:edge sh -c "
  apk add --no-cache gcc musl-dev >/dev/null 2>&1
  gcc --version | head -1
  gcc -O2 -fno-builtin-fmod -o /tmp/probe /src/zen-probe.c -lm
  /tmp/probe
" | tee "$out/alpine.txt"
if grep -q MISMATCH "$out/alpine.txt"; then
  echo "FAIL: mismatch on musl" >&2; exit 1
fi
exit 0
