#!/bin/sh
# Sample one browser kernel with `perf` and report where the CPU time went.
#
# Runs INSIDE the arm's own container, deliberately. perf resolves a sample to a
# DSO from the mmap records the kernel emits, and those carry the path as the
# sampled process sees it — so a perf running in the same mount namespace
# resolves them and a perf on the host does not. Both arms therefore profile
# themselves with their own distro's perf, and only the reports are compared.
#
# What the report can and cannot say: chromium ships stripped on BOTH sides
# (ours by stage-cache-layout.sh, official by Google) and our build is
# symbol_level = 0, so there is no DWARF anywhere either. Function names are
# therefore largely unavailable and the DSO column is the finding — which is the
# question anyway. "Time inside libz.so.1" and "time inside the main binary" are
# different answers with different fixes.
#
# usage: perf-profile.sh <target> <kernel> <outdir> <probe.cjs> <perf-binary>
set -eu

TARGET="${1:?target}"
KERNEL="${2:?kernel}"
OUT="${3:?outdir}"
PROBE="${4:?probe path}"
PERF="${5:?perf binary}"

# The probe loops for LOOP seconds; sampling takes the first RECORD_WINDOW of
# that and counting the next STAT_WINDOW, both strictly inside the steady state
# so neither window contains a launch or a warmup.
LOOP="${PERF_LOOP_SECONDS:-80}"
RECORD_WINDOW="${PERF_RECORD_WINDOW:-30}"
STAT_WINDOW="${PERF_STAT_WINDOW:-20}"

READY="/tmp/perf-ready-${TARGET}-${KERNEL}"
rm -f "$READY"
mkdir -p "$OUT"
PROBE_LOG="${OUT}/${TARGET}-${KERNEL}-probe.log"

echo "=== ${TARGET} / ${KERNEL}: starting probe ==="
node "$PROBE" --target "$TARGET" --kernel "$KERNEL" --seconds "$LOOP" \
  --out "$OUT" --ready "$READY" > "$PROBE_LOG" 2>&1 &
PROBE_PID=$!

# Poll for the probe's own steady-state marker rather than sleeping a guessed
# amount: the two arms warm up at measurably different speeds, and a fixed
# delay would sample a different phase on each side.
waited=0
while [ ! -f "$READY" ]; do
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    echo "probe exited before reaching steady state:" >&2
    cat "$PROBE_LOG" >&2
    exit 1
  fi
  if [ "$waited" -ge 180 ]; then
    echo "probe never reached steady state within 180s" >&2
    cat "$PROBE_LOG" >&2
    kill "$PROBE_PID" 2>/dev/null || true
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
echo "steady state after ${waited}s"

DATA="${OUT}/${TARGET}-${KERNEL}.data"

# -a because chromium spreads the work over browser, renderer, GPU and its
# thread pools, and following only the launcher would profile node — but -a on
# its own also samples whatever else the machine is doing, which on a developer
# box is other containers. `-G /` narrows it back to this container's own
# cgroup, which under a cgroup namespace is exactly the arm and nothing else.
#
# cpu-clock rather than the default `cycles`: hosted runners are VMs and the
# hardware PMU is frequently not virtualised through, in which case a `cycles`
# record silently produces an empty profile. cpu-clock is a software event, is
# always available, and answers "where did the CPU time go".
record() {
  "$PERF" record -e cpu-clock -F 999 -a "$@" --no-buildid-cache \
    -o "$DATA" -- sleep "$RECORD_WINDOW" 2>&1 | sed 's/^/  perf-record: /'
}
samples_in() {
  "$PERF" report -i "$DATA" --stdio --sort dso 2>/dev/null \
    | grep -c '%' || true
}

record -G /
if [ "$(samples_in)" -eq 0 ]; then
  # An empty profile is indistinguishable from "the kernel does no work", so
  # never report one: cgroup filtering is the part most likely to behave
  # differently on another host, and a system-wide profile with foreign
  # processes in it still answers the question.
  echo "cgroup-filtered record produced no samples — falling back to -a" >&2
  record
fi

# The record window length, so the report can turn a share-of-samples into
# CPU-ms per iteration. It has to: on a hosted runner both arms' screenshot
# wall time sits on the compositor cadence, and a percentage of an unknown
# total says nothing about which arm did more work.
echo "$RECORD_WINDOW" > "${OUT}/${TARGET}-${KERNEL}-window"

echo "--- ${TARGET} / ${KERNEL}: by DSO ---"
"$PERF" report -i "$DATA" --stdio --sort dso --percent-limit 0.1 -g none \
  > "${OUT}/${TARGET}-${KERNEL}-dso.txt" 2>&1 || true
head -40 "${OUT}/${TARGET}-${KERNEL}-dso.txt"

"$PERF" report -i "$DATA" --stdio --sort comm,dso --percent-limit 0.1 -g none \
  > "${OUT}/${TARGET}-${KERNEL}-comm-dso.txt" 2>&1 || true
"$PERF" report -i "$DATA" --stdio --sort dso,sym --percent-limit 0.1 -g none \
  > "${OUT}/${TARGET}-${KERNEL}-sym.txt" 2>&1 || true

# Counting, not sampling. The hardware pair separates "we run more
# instructions" (codegen, extra library calls) from "we run the same
# instructions slower" (cache, branches, memory) — but they are exactly what a
# VM tends not to expose, so the hardware list is allowed to fail and the
# software list, which cannot, is collected separately.
HW='cycles,instructions,branches,branch-misses,cache-references,cache-misses'
SW='task-clock,context-switches,cpu-migrations,page-faults,minor-faults'
{
  # -e BEFORE -G, always: perf stat rejects a cgroup it has no event to
  # attach yet with "must define events before cgroups", and the `|| true`
  # would otherwise turn that into a silently empty counter block.
  echo "### ${TARGET} / ${KERNEL} — hardware counters (a VM may refuse these)"
  "$PERF" stat -e "$HW" -a -G / -- sleep "$STAT_WINDOW" 2>&1 || true
  echo
  echo "### ${TARGET} / ${KERNEL} — software counters"
  "$PERF" stat -e "$SW" -a -G / -- sleep 5 2>&1 || true
} > "${OUT}/${TARGET}-${KERNEL}-stat.txt"
cat "${OUT}/${TARGET}-${KERNEL}-stat.txt"

wait "$PROBE_PID" || {
  echo "probe failed after profiling:" >&2
  cat "$PROBE_LOG" >&2
  exit 1
}
tail -5 "$PROBE_LOG"
