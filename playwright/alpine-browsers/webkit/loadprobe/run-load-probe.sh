#!/bin/sh
# Times what `launch` mostly is: mapping libWPEWebKit and processing its
# ~320,000 relocations. Run against ONE library path; the workflow runs it in
# our image and in the official one on the SAME runner so the two are
# comparable.
#
# Why this probe exists: `launch` is 1.37x official and did not move with the
# allocator. Two candidates are already dead — the DSO closure (ours 60
# DT_NEEDED against official's 70, so ours is the leaner side) and BIND_NOW
# (a within-binary RTLD_NOW/RTLD_LAZY A/B on official showed no cost). Ours
# also has FEWER relocations (320,694 vs 339,342) and a SMALLER .text, and
# still appeared to load slower on a laptop. That points at musl's dynamic
# loader rather than at our build, and it needs a quiet machine to confirm.
set -eu

LIB="${1:?usage: run-load-probe.sh <libWPEWebKit path> [reps]}"
REPS="${2:-12}"
BIN="${LOADBENCH:-/tmp/loadbench}"

echo "===== $LIB"
[ -f "$LIB" ] || { echo "FAIL: no such library" >&2; exit 1; }

# Static shape first — the numbers that make the timing interpretable.
if command -v readelf >/dev/null 2>&1; then
  echo "  DT_NEEDED:    $(readelf -d "$LIB" | grep -c NEEDED)"
  echo "  relocations:  $(readelf -r "$LIB" 2>/dev/null | grep -c '^[0-9a-f]')"
  echo "  bind-now:     $(readelf -d "$LIB" | grep -cE 'BIND_NOW|Flags: NOW')"
  echo "  .text bytes:  $(readelf -S -W "$LIB" | awk '$2==".text"{print $6}')"
fi

# Alternate the modes rather than blocking them, so a machine that drifts
# part-way through cannot land entirely on one. A load is a floor
# measurement — noise only ever adds — so the best of each is the number.
i=0
while [ "$i" -lt "$REPS" ]; do
  "$BIN" "$LIB" lazy
  "$BIN" "$LIB" now
  i=$((i + 1))
done
