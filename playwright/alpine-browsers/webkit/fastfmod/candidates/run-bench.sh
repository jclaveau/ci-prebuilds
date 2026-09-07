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

# The entry reduction PR #170 replaced: a full hardware divide where the
# shipped source now does one conditional subtract. It was justified on a dev
# box (269.5 ms -> 170.2), and this file's own header says dividers rank
# differently per core — so it gets timed here, on the CI part, beside the
# thing it replaced. Generated from the shipped source rather than copied, so
# the two candidates cannot drift apart.
sed -e 's|uint64_t excess = mx - my;|uint64_t excess = mx % my;|' \
    -e 's|mx = (excess >> 63) ? mx : excess;|mx = excess;|' \
    "$here/../fastfmod.c" > "$out/entry-divide.c"

for src in "$here/../fastfmod.c" "$here"/*.c "$out/entry-divide.c"; do
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
