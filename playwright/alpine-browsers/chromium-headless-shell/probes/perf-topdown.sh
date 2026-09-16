#!/bin/sh
# Topdown (TMA) counters for one browser kernel, inside the arm's own container.
# usage: perf-topdown.sh <target> <kernel> <outdir> <probe.cjs> <perf-binary>
set -eu
TARGET="$1"; KERNEL="$2"; OUT="$3"; PROBE="$4"; PERF="$5"
LOOP="${PERF_LOOP_SECONDS:-130}"
READY="/tmp/perf-ready-${TARGET}-${KERNEL}"
rm -f "$READY"; mkdir -p "$OUT"
LOG="${OUT}/${TARGET}-${KERNEL}-probe.log"
node "$PROBE" --target "$TARGET" --kernel "$KERNEL" --seconds "$LOOP" \
  --out "$OUT" --ready "$READY" > "$LOG" 2>&1 &
PID=$!
w=0
while [ ! -f "$READY" ]; do
  kill -0 "$PID" 2>/dev/null || { echo "probe died:"; cat "$LOG"; exit 1; }
  [ "$w" -ge 180 ] && { echo "no steady state in 180s"; kill "$PID"; exit 1; }
  sleep 1; w=$((w+1))
done
echo "steady after ${w}s"
{
  echo "### $TARGET / $KERNEL — TopdownL1"
  "$PERF" stat -M TopdownL1 -a --for-each-cgroup / -- sleep 20 2>&1
  echo "### $TARGET / $KERNEL — TopdownL2"
  "$PERF" stat -M TopdownL2 -a --for-each-cgroup / -- sleep 25 2>&1
  echo "### $TARGET / $KERNEL — fetch"
  "$PERF" stat -e cycles,instructions,L1-icache-load-misses,iTLB-load-misses,iTLB-loads,branches,branch-misses -a -G / -- sleep 15 2>&1
  echo "### $TARGET / $KERNEL — data"
  "$PERF" stat -e L1-dcache-load-misses,LLC-load-misses,dTLB-load-misses -a -G / -- sleep 10 2>&1
} > "${OUT}/${TARGET}-${KERNEL}-topdown.txt"
cat "${OUT}/${TARGET}-${KERNEL}-topdown.txt"
wait "$PID" || { echo "probe failed:"; cat "$LOG"; exit 1; }
grep -i "iter\|ms" "$LOG" | tail -5
