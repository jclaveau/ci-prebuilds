#!/bin/sh
# Time every fmod candidate against the libc of whatever image this runs in,
# and gate each one on bit-identical results.
#
# It runs in BOTH images on ONE runner, which is the only way the numbers mean
# anything: the shipped shim is measured against musl in ours and against
# glibc in Playwright's, and hosted runners hand out a different CPU per job.
# It also has to be a real machine rather than a dev box — the candidates
# differ by ~25 cycles per call, and the divide-based ones live or die on the
# divider latency of the specific core (Zen 4's 64-bit DIV is ~19 cycles;
# older parts are several times that, which inverted the ranking locally).
set -eu

here="$(dirname "$0")"
cc="${CC:-gcc}"
out="${TMPDIR:-/tmp}"

for src in "$here/../fastfmod.c" "$here"/*.c; do
  name="$(basename "$src" .c)"
  case "$name" in
    bench-harness) continue ;;
  esac
  # The candidates all export `fmod`, which is the point of them; renaming it
  # lets the harness hold both the candidate and the platform's own in one
  # binary and compare results call for call.
  $cc -O2 -fno-builtin-fmod -Dfmod=cand_fmod -c "$src" -o "$out/$name.o"
  $cc -O2 -fno-builtin-fmod "$here/bench-harness.c" "$out/$name.o" \
      -o "$out/h_$name" -lm
  printf '%-18s ' "$name"
  "$out/h_$name"
done
