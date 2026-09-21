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
# One-sided exception, for OUR binary only: when the caller mounts the chain's
# link census at /out/census (symtab.nm.gz from link-census.sh), the samples in
# the main binary are named and the hottest functions annotated per
# instruction by perf-symbolize.py. That is how the fortify overlap check was
# found — the DSO table had said "the main binary" for weeks.
#
# Passes, in order, all inside one steady-state loop of the kernel:
#   cpu-clock record   where the CPU TIME goes (DSO, thread, symbol)
#   callers record     who calls memset (fp unwind, first hop only)
#   instructions record where the INSTRUCTIONS go — a different answer when
#                      the IPC differs, and ours runs +50% instructions at a
#                      higher IPC on goto_warm (PR #268), so time-weighted
#                      sampling under-reports exactly the code that is extra
#   perf stat          counters: HW pair, stalls, caches, SW, topdown metrics
#   perf sched         wake-up latency per thread: CPU-bound and latency-bound
#                      look the same in a cpu-clock profile, and a musl futex
#                      hand-off that costs a millisecond per frame is invisible
#                      to everything above
#   strace -c -w       syscall histogram per iteration, wall time: launch's
#                      ICU/tzdata walk was found this way, and futex wall time
#                      is thread waiting, named
# Every window is bracketed by the probe's iteration counter, so each pass can
# be normalised per iteration on its own, not by a rate extrapolated from the
# whole loop.
#
# Browser-generic since the webkit/firefox arm (browser-perf-record.yml):
# PROBE_BROWSER picks the engine perf-kernel.cjs drives, the binary the census
# names, the DSO the symbol tables select and the process pattern strace
# attaches to. Names for a stripped webkit/firefox come from an unstripped
# twin the caller drops in $PERF_SYMBOLS_DIR (the producer's pre-strip dist),
# served to perf through a symfs — the same file with its .symtab kept. The
# twin is OUR build's, so it only names the alpine target: official ships a
# different link of the same library, and perf would name its addresses off
# the wrong table without a word. The libraries carry no build-id, so the
# match is geometric — strip leaves .text where it was, a foreign link does not.
#
# usage: perf-profile.sh <target> <kernel> <outdir> <probe.cjs> <perf-binary>
set -eu

TARGET="${1:?target}"
KERNEL="${2:?kernel}"
OUT="${3:?outdir}"
PROBE="${4:?probe path}"
PERF="${5:?perf binary}"
BROWSER="${PROBE_BROWSER:-chromium}"
SYMBOLS_DIR="${PERF_SYMBOLS_DIR:-/out/symbols}"

case "$BROWSER" in
  chromium)
    # The .real behind the sh shim where the consumer image has one.
    BIN=$(ls /ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell.real 2>/dev/null \
       || ls /ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell 2>/dev/null \
       || true)
    DSO_PATTERN='chrome-headless-shell'
    PROC_PATTERN='^/ms-playwright/[^ ]*chrome-headless-shell' ;;
  webkit)
    BIN=$(ls /ms-playwright/webkit-*/minibrowser-wpe/libWPEWebKit-*.so.*.*.* 2>/dev/null | head -1 || true)
    DSO_PATTERN='libWPEWebKit'
    # MiniBrowser, WPEWebProcess, WPENetworkProcess, WPEGPUProcess: every
    # one execs from the bundle dir.
    PROC_PATTERN='^/ms-playwright/webkit-[^ ]*/minibrowser-wpe/' ;;
  firefox)
    BIN=$(ls /ms-playwright/firefox-*/firefox/libxul.so 2>/dev/null | head -1 || true)
    DSO_PATTERN='libxul'
    # firefox.real behind the shim on ours, firefox on official; content and
    # utility processes re-exec the same binary.
    PROC_PATTERN='^/ms-playwright/firefox-[^ ]*/firefox/firefox' ;;
  *)
    echo "unknown PROBE_BROWSER $BROWSER" >&2
    exit 2 ;;
esac

# The probe loops for LOOP seconds; sampling takes the first RECORD_WINDOW of
# that and counting the next STAT_WINDOW, both strictly inside the steady state
# so neither window contains a launch or a warmup.
LOOP="${PERF_LOOP_SECONDS:-200}"
RECORD_WINDOW="${PERF_RECORD_WINDOW:-30}"
STAT_WINDOW="${PERF_STAT_WINDOW:-20}"
CG_WINDOW="${PERF_CALLGRAPH_WINDOW:-20}"
INSN_WINDOW="${PERF_INSN_WINDOW:-15}"
TOPDOWN_WINDOW="${PERF_TOPDOWN_WINDOW:-15}"
SCHED_WINDOW="${PERF_SCHED_WINDOW:-10}"
STRACE_WINDOW="${PERF_STRACE_WINDOW:-15}"

READY="/tmp/perf-ready-${TARGET}-${KERNEL}"
rm -f "$READY"
mkdir -p "$OUT"
PROBE_LOG="${OUT}/${TARGET}-${KERNEL}-probe.log"
PROGRESS="${OUT}/${TARGET}-${KERNEL}-progress"
WINDOWS="${OUT}/${TARGET}-${KERNEL}-windows.txt"
rm -f "$PROGRESS" "$WINDOWS"

# The probe writes its iteration count to $PROGRESS after every iteration;
# bracketing a pass with it says how many iterations that pass saw, so the
# pass normalises per iteration on its own. `window <name> <seconds> <before>
# <after>` lines, one per pass, read back by perf-record-report.py.
iters_now() { cat "$PROGRESS" 2>/dev/null || echo 0; }
window_open() { WIN_NAME="$1"; WIN_SECS="$2"; WIN_BEFORE=$(iters_now); }
window_close() {
  echo "$WIN_NAME $WIN_SECS $WIN_BEFORE $(iters_now)" >> "$WINDOWS"
}

echo "=== ${TARGET} / ${KERNEL}: starting probe ==="
node "$PROBE" --browser "$BROWSER" --target "$TARGET" --kernel "$KERNEL" \
  --seconds "$LOOP" --out "$OUT" --ready "$READY" > "$PROBE_LOG" 2>&1 &
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

window_open cpu-clock "$RECORD_WINDOW"
record -G /
window_close
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

# Every report is generated AFTER the probe has finished (see the bottom of
# this file): a `perf report` over a 30 s system-wide profile and the
# symbolization pass take tens of seconds each, and run between two capture
# passes they pushed the later passes past the end of the loop — the first
# local run had `stat`, `topdown` and `sched` bracketed 463→463 iterations,
# i.e. sampling an exited browser. Capture first, read later.

# A SECOND record, for callers only. The flat pass above answers "which DSO
# burns the time"; run 34406201201 answered it — `memset` in ld-musl is 6.30% of
# alpine samples, the hottest symbol by 5x, against 2.54% for the whole of
# glibc. What it cannot answer is who calls it, and that decides the fix. A
# caller in the main binary is reachable by an LD_PRELOAD, the pattern already
# shipped for mimalloc and zlib-ng; a caller inside musl itself is not, and
# needs the libc rebuilt.
#
# fp rather than dwarf, which is the counter-intuitive half. dwarf unwinds from
# .eh_frame, and musl writes memset in hand-rolled asm with no CFI at all, so
# the unwind dies on its first step out of the one symbol this pass exists for
# (measured in alpine:edge: `---0xffffffffffffffff` then memset, no caller).
# fp resolves the same chain, because memset is a leaf that never touches rbp
# and the register still holds the caller frame. Only the FIRST hop is load
# bearing here: chromium is compiled without frame pointers, so treat anything
# above the immediate caller as noise.
CG_DATA="${OUT}/${TARGET}-${KERNEL}-cg.data"
window_open callers "$CG_WINDOW"
"$PERF" record -e cpu-clock -F 999 -a -G / --call-graph fp \
  --no-buildid-cache -o "$CG_DATA" -- sleep "$CG_WINDOW" \
  2>&1 | sed 's/^/  perf-cg: /' || true
window_close


# A THIRD record, weighted by instructions rather than by time. cpu-clock
# says where the seconds go; with ours running MORE instructions at a HIGHER
# IPC than official (goto_warm, PR #268), the extra instructions are by
# definition the ones that retire fastest, and a time-weighted profile
# under-reports them. Sampling on the `instructions` event puts each sample
# where an instruction retired, so a function that is 5% of the time and 12%
# of the instructions reads as 12% here — that is the code that is extra.
# A hardware event, so a VM may refuse it; an empty profile is reported as
# absent, never as zero.
INSN_DATA="${OUT}/${TARGET}-${KERNEL}-insn.data"
window_open instructions "$INSN_WINDOW"
"$PERF" record -e instructions -F 999 -a -G / --no-buildid-cache \
  -o "$INSN_DATA" -- sleep "$INSN_WINDOW" 2>&1 | sed 's/^/  perf-insn: /' || true
window_close

# Counting, not sampling. The hardware pair separates "we run more
# instructions" (codegen, extra library calls) from "we run the same
# instructions slower" (cache, branches, memory) — but they are exactly what a
# VM tends not to expose, so the hardware list is allowed to fail and the
# software list, which cannot, is collected separately.
#
# How often they are refused: run 34342006293 got NO hardware PMU at all, not
# even `cycles`, on both arms — every block came back `<not supported>`. That
# is a property of the runner, not of the events, and it varies between runs on
# the same label. So a counter-based claim has to check the block is populated
# before it is quoted, and an unpopulated one means re-run, not "the counters
# say nothing".
HW='cycles,instructions,branches,branch-misses,cache-references,cache-misses'
# The frontend/backend split, asked separately because it is the part most
# likely to be absent on a VM and a single unsupported event makes perf reject
# the WHOLE list rather than the one it cannot count. The first read of layout
# put us at +16% instructions and -13% IPC, and nothing since has said why the
# IPC is down: frontend stalls would mean code layout and instruction-fetch
# (which an orderfile addresses), backend stalls would mean memory. They lead
# to different fixes and no counter collected so far separates them.
STALL='stalled-cycles-frontend,stalled-cycles-backend'
CACHE='L1-icache-load-misses,iTLB-load-misses,L1-dcache-load-misses'
SW='task-clock,context-switches,cpu-migrations,page-faults,minor-faults'
# Beyond L1i/iTLB: the dev-box topdown pass read the layout gap as
# instruction FETCH (iTLB 2.3x, icache 1.4x) on an i5; these are the same
# events on the fleet's own CPU, plus LLC and dTLB so a data-side story can be
# ruled in or out with the same read. Its own block, since one unsupported
# event rejects the whole list.
FETCH='iTLB-loads,LLC-load-misses,dTLB-load-misses'
window_open stat "$((STAT_WINDOW + 25))"
{
  # -e BEFORE -G, always: perf stat rejects a cgroup it has no event to
  # attach yet with "must define events before cgroups", and the `|| true`
  # would otherwise turn that into a silently empty counter block.
  echo "### ${TARGET} / ${KERNEL} — hardware counters (a VM may refuse these)"
  "$PERF" stat -e "$HW" -a -G / -- sleep "$STAT_WINDOW" 2>&1 || true
  echo
  echo "### ${TARGET} / ${KERNEL} — where the stalls are"
  "$PERF" stat -e "$STALL" -a -G / -- sleep 10 2>&1 || true
  echo
  echo "### ${TARGET} / ${KERNEL} — instruction and data cache"
  "$PERF" stat -e "$CACHE" -a -G / -- sleep 10 2>&1 || true
  echo
  echo "### ${TARGET} / ${KERNEL} — software counters"
  "$PERF" stat -e "$SW" -a -G / -- sleep 5 2>&1 || true
  echo
  echo "### ${TARGET} / ${KERNEL} — fetch and data, extended"
  "$PERF" stat -e "$FETCH" -a -G / -- sleep 5 2>&1 || true
} > "${OUT}/${TARGET}-${KERNEL}-stat.txt"
window_close

# Topdown level 1: retiring / bad speculation / frontend bound / backend
# bound, as the PMU's own metric group. Intel names it TopdownL1, AMD's
# zen4 tables carry PipelineL1; whichever this runner's perf lists is the
# one asked for, and a runner with neither (or no PMU) writes an empty file.
# --for-each-cgroup rather than -G: -M rejects a bare cgroup filter.
window_open topdown "$TOPDOWN_WINDOW"
{
  echo "### ${TARGET} / ${KERNEL} — topdown level 1"
  found=0
  for M in TopdownL1 PipelineL1; do
    if "$PERF" list metricgroups 2>/dev/null | grep -q "^${M} "; then
      found=1
      echo "metric group: ${M}"
      "$PERF" stat -M "$M" -a --for-each-cgroup / -- sleep "$TOPDOWN_WINDOW" 2>&1 || true
      break
    fi
  done
  [ "$found" = 1 ] || echo "no TopdownL1/PipelineL1 metric group on this runner (no hardware PMU)"
} > "${OUT}/${TARGET}-${KERNEL}-topdown.txt"
window_close

# Scheduler latency per thread. cpu-clock samples on-CPU time only: a thread
# that spends a millisecond per frame waiting to be woken costs wall time
# and shows in no profile above. `perf sched latency` reads the switch and
# wakeup tracepoints and prints, per task, runtime, switches, and the delay
# between wakeup and running. The two arms' compositor / raster / IO threads
# side by side is the CPU-bound-vs-latency-bound question, answered per
# thread. Tracepoints need tracefs; the caller mounts /sys/kernel/tracing,
# and a container without it writes an empty file rather than failing. The
# caller also runs this container in the host pid namespace, or the
# tracepoint pids never meet the names in /proc and every row is `:pid`.
SCHED_DATA="${OUT}/${TARGET}-${KERNEL}-sched.data"
window_open sched "$SCHED_WINDOW"
"$PERF" sched record -a -G / -o "$SCHED_DATA" -- sleep "$SCHED_WINDOW" \
  2>&1 | sed 's/^/  perf-sched: /' || true
window_close

# Syscalls, wall-clock, per iteration. ptrace slows the browser down (so
# this pass is LAST, after every sample has been taken) but the counts per
# iteration are what is read, not the speed, and launch's 9,300 extra file
# syscalls (ICU walking tzdata) were found with exactly this table. -w
# rather than the default system time: futex wall time is time a thread
# spent WAITING, which is the latency question again from the other side.
# Anchored on the exec path: under --pid=host (see the workflow) a bare
# substring would also match the shell whose -c script mentions the wrapper
# path, and strace would attach to itself.
# A launch kernel relaunches the browser every iteration (official webkit:
# one every 70 ms), so a single pgrep can land between two processes; retry,
# then fall back to following the probe's children, which catches every
# launch from exec onwards.
if command -v strace >/dev/null 2>&1; then
  pids=""
  for _try in 1 2 3; do
    pids=$(pgrep -f "$PROC_PATTERN" | sed 's/^/-p /' | tr '\n' ' ')
    [ -n "$pids" ] && break
    sleep 1
  done
  attached="browser"
  if [ -z "$pids" ]; then
    pids="-p $PROBE_PID"
    attached="probe (browser pid not caught by pgrep; children followed)"
  fi
  window_open strace "$STRACE_WINDOW"
  {
    echo "# strace attached to: ${attached}"
    # shellcheck disable=SC2086
    timeout -s INT "$STRACE_WINDOW" strace -f -c -w $pids 2>&1 || true
  } > "${OUT}/${TARGET}-${KERNEL}-strace.txt"
  window_close
else
  echo "strace not installed in the perf image" \
    > "${OUT}/${TARGET}-${KERNEL}-strace-unavailable"
fi

wait "$PROBE_PID" || {
  echo "probe failed after profiling:" >&2
  cat "$PROBE_LOG" >&2
  exit 1
}
tail -5 "$PROBE_LOG"
echo "passes and the iterations each saw:"
cat "$WINDOWS"

# ---- Reports, with the browser gone and the clock no longer a concern ----

echo "--- ${TARGET} / ${KERNEL}: by DSO ---"
"$PERF" report -i "$DATA" --stdio --sort dso --percent-limit 0.1 -g none \
  > "${OUT}/${TARGET}-${KERNEL}-dso.txt" 2>&1 || true
head -40 "${OUT}/${TARGET}-${KERNEL}-dso.txt"

"$PERF" report -i "$DATA" --stdio --sort comm,dso --percent-limit 0.1 -g none \
  > "${OUT}/${TARGET}-${KERNEL}-comm-dso.txt" 2>&1 || true

# The engine's DSO as perf names it — the basename of the path the loader
# mapped, which for a library is its soname symlink (libWPEWebKit-2.0.so.1)
# and not the file the build produced. Read from the profile rather than
# guessed from the filesystem for that reason.
DSO=$(grep -o "${DSO_PATTERN}[^ ]*" "${OUT}/${TARGET}-${KERNEL}-dso.txt" | head -1)
DSO="${DSO:-$(basename "${BIN:-$DSO_PATTERN}")}"
echo "engine DSO: ${DSO}"

# A symfs for a stripped engine whose unstripped twin the caller mounted: the
# tree perf resolves is the container's own, with the one library swapped.
# Symlinks, not copies — perf opens symfs + recorded path, and a link is
# enough for everything except the twin itself.
SYMFS=""
if [ -d "$SYMBOLS_DIR" ] && [ "$BROWSER" != chromium ]; then
  mapped=$(find /ms-playwright -name "$DSO" 2>/dev/null | head -1)
  real=$(readlink -f "${mapped:-/nonexistent}" 2>/dev/null || true)
  twin=$(find "$SYMBOLS_DIR" -name "$(basename "${real:-/nonexistent}")" -type f 2>/dev/null | head -1)
  text_geometry() { readelf -S -W "$1" 2>/dev/null | sed -n 's/^.*\] \.text  *//p' | awk '{ print $2, $4 }'; }
  if [ -n "$mapped" ] && [ -n "$twin" ] \
     && [ "$(readelf -S -W "$twin" | grep -c '\.symtab')" -gt 0 ] \
     && [ "$(text_geometry "$real")" = "$(text_geometry "$twin")" ]; then
    SYMFS=/tmp/symfs
    rm -rf "$SYMFS"
    mkdir -p "$SYMFS$(dirname "$mapped")"
    for d in /lib /lib64 /usr; do
      [ -e "$d" ] && ln -s "$d" "$SYMFS$d"
    done
    cp -rs "$(dirname "$mapped")/." "$SYMFS$(dirname "$mapped")/"
    ln -sf "$twin" "$SYMFS$mapped"
    echo "symfs: ${mapped} -> ${twin} ($(stat -c %s "$twin") bytes, .symtab kept)"
  else
    echo "no unstripped twin matching ${DSO} under ${SYMBOLS_DIR} — engine samples stay unnamed"
  fi
fi
"$PERF" report -i "$DATA" --stdio --sort dso,sym --percent-limit 0.1 -g none \
  > "${OUT}/${TARGET}-${KERNEL}-sym.txt" 2>&1 || true

# The main binary, every sample, by thread and unresolved address: the input
# perf-symbolize.py names. Its own file rather than a percent-limited one,
# because a symbol that is 0.3% on each of 30 addresses is 9% of the binary.
"$PERF" report -i "$DATA" --stdio -n --sort comm,sym --dsos "$DSO" \
  --percent-limit 0 -g none \
  > "${OUT}/${TARGET}-${KERNEL}-commsym.txt" 2>&1 || true

# Names straight from perf when the twin is in the symfs: the engine's
# samples resolve like any other DSO's, no census and no PIE arithmetic.
# Same file name as the census path writes, so the report embeds either.
# Percentages are the engine's own (--percentage relative): a kernel that
# spends 0.5% of its time in the engine — launch is the loader and the
# kernel — still lists what that 0.5% is, instead of an empty table.
named_symbols() {
  {
    echo "### ${TARGET} / ${KERNEL} — hot symbols, $2, ${DSO} named from its unstripped twin (share of the engine's own samples)"
    echo
    echo '```'
    "$PERF" report -i "$1" --stdio -n --sort comm,sym --dsos "$DSO" --symfs "$SYMFS" \
      --percentage relative --percent-limit 0.2 -g none 2>/dev/null | grep -v '^#' | grep -v '^$' | head -60
    echo '```'
  } > "$3" || true
}
if [ -n "$SYMFS" ]; then
  named_symbols "$DATA" "time-weighted (cpu-clock)" "${OUT}/${TARGET}-${KERNEL}-symbols.md"
  head -50 "${OUT}/${TARGET}-${KERNEL}-symbols.md"
fi

if [ -s "$CG_DATA" ]; then
  echo "--- ${TARGET} / ${KERNEL}: callers ---"
  # shellcheck disable=SC2086
  "$PERF" report -i "$CG_DATA" --stdio --no-children -g graph,0.5,caller \
    --sort dso,sym --percent-limit 0.5 ${SYMFS:+--symfs "$SYMFS"} \
    > "${OUT}/${TARGET}-${KERNEL}-callers.txt" 2>&1 || true
  head -60 "${OUT}/${TARGET}-${KERNEL}-callers.txt"

  # The one symbol this pass exists for, kept in its own file so it survives
  # the percent-limit that keeps the general report readable.
  #
  # Two things had to change for the official leg to show anything here, and
  # the first run of this pass (34504703616) showed neither: its memset-callers
  # file was 317 bytes of header while alpine's was 51 KB.
  #
  #   - glibc IFUNCs memset at load to a CPU-specific body, and perf reports the
  #     body it sampled — `__memset_avx2_unaligned_erms` on the runners seen so
  #     far, evex/avx512 variants on others. So `--symbols memset`, an exact
  #     match, can never hit on that side; a substring filter can.
  #   - Ubuntu's libc.so.6 is stripped, so without libc6-dbg the sampled body
  #     has no name at all and shows as `libc.so.6 [.] 0x1a1bfa`. That is what
  #     the run above produced. Dockerfile.perf-official now installs the
  #     debug symbols, which perf finds by build-id.
  #
  # A control that cannot show anything is not a control.
  # shellcheck disable=SC2086
  "$PERF" report -i "$CG_DATA" --stdio --no-children -g graph,0,caller \
    --sort dso,sym --symbol-filter=memset ${SYMFS:+--symfs "$SYMFS"} \
    > "${OUT}/${TARGET}-${KERNEL}-memset-callers.txt" 2>&1 || true
  cat "${OUT}/${TARGET}-${KERNEL}-memset-callers.txt"
fi
# Only the reports above are read afterwards, and perf.data is the big file.
rm -f "$CG_DATA"

if [ -s "$INSN_DATA" ] && [ "$("$PERF" report -i "$INSN_DATA" --stdio --sort dso 2>/dev/null | grep -c '%' || true)" -gt 0 ]; then
  "$PERF" report -i "$INSN_DATA" --stdio --sort dso --percent-limit 0.1 -g none \
    > "${OUT}/${TARGET}-${KERNEL}-insn-dso.txt" 2>&1 || true
  "$PERF" report -i "$INSN_DATA" --stdio --sort comm,dso --percent-limit 0.1 -g none \
    > "${OUT}/${TARGET}-${KERNEL}-insn-comm-dso.txt" 2>&1 || true
  "$PERF" report -i "$INSN_DATA" --stdio -n --sort comm,sym --dsos "$DSO" \
    --percent-limit 0 -g none \
    > "${OUT}/${TARGET}-${KERNEL}-insn-commsym.txt" 2>&1 || true
  echo "--- ${TARGET} / ${KERNEL}: by DSO, instruction-weighted ---"
  head -20 "${OUT}/${TARGET}-${KERNEL}-insn-dso.txt"
  if [ -n "$SYMFS" ]; then
    named_symbols "$INSN_DATA" "instruction-weighted" "${OUT}/${TARGET}-${KERNEL}-insn-symbols.md"
  fi
else
  echo "instructions record produced no samples (no hardware PMU on this runner)" \
    | tee "${OUT}/${TARGET}-${KERNEL}-insn-unavailable"
fi
rm -f "$INSN_DATA"

# Names, for our binary only, when the chain's link census is mounted. The
# PIE shift is read from the binary: perf's unresolved address is a file
# offset, nm's is a virtual address, and the .text LOAD segment's
# p_vaddr - p_offset is the difference (0x1000 on every build so far, but a
# different linker script would move it silently).
if [ -n "$SYMFS" ]; then
  : # named above, straight from perf, through the symfs
elif [ -n "$BIN" ] && [ -s /out/census/symtab.nm.gz ]; then
  set -- $(readelf -lW "$BIN" | awk '/LOAD/ && / R E /{print $2, $3; exit}')
  DELTA=$(printf '0x%x' $(( $2 - $1 )))
  echo "symbolizing ${DSO} with /out/census (PIE delta ${DELTA})"
  python3 /probe/perf-symbolize.py --nm /out/census/symtab.nm.gz \
    --binary "$BIN" --delta "$DELTA" \
    --report "${OUT}/${TARGET}-${KERNEL}-commsym.txt" --top 40 --annotate 8 \
    --title "${TARGET} / ${KERNEL} — hot symbols, time-weighted (cpu-clock)" \
    > "${OUT}/${TARGET}-${KERNEL}-symbols.md" 2>&1 || true
  head -50 "${OUT}/${TARGET}-${KERNEL}-symbols.md"
  if [ -s "${OUT}/${TARGET}-${KERNEL}-insn-commsym.txt" ]; then
    python3 /probe/perf-symbolize.py --nm /out/census/symtab.nm.gz \
      --binary "$BIN" --delta "$DELTA" \
      --report "${OUT}/${TARGET}-${KERNEL}-insn-commsym.txt" --top 40 --annotate 4 \
      --title "${TARGET} / ${KERNEL} — hot symbols, instruction-weighted" \
      > "${OUT}/${TARGET}-${KERNEL}-insn-symbols.md" 2>&1 || true
  fi
elif [ "$TARGET" = alpine ] && [ "$BROWSER" = chromium ]; then
  echo "no link census at /out/census — main-binary samples stay unnamed (pass census_run_id)"
fi

cat "${OUT}/${TARGET}-${KERNEL}-stat.txt"
cat "${OUT}/${TARGET}-${KERNEL}-topdown.txt"

if [ -s "$SCHED_DATA" ]; then
  "$PERF" sched latency -i "$SCHED_DATA" --sort max 2>/dev/null \
    > "${OUT}/${TARGET}-${KERNEL}-sched.txt" || true
  echo "--- ${TARGET} / ${KERNEL}: scheduler latency, top by max delay ---"
  head -20 "${OUT}/${TARGET}-${KERNEL}-sched.txt"
fi
rm -f "$SCHED_DATA"

if [ -s "${OUT}/${TARGET}-${KERNEL}-strace.txt" ]; then
  echo "--- ${TARGET} / ${KERNEL}: syscalls (wall), ${STRACE_WINDOW}s ---"
  grep -v '^strace: Process' "${OUT}/${TARGET}-${KERNEL}-strace.txt" | head -25
fi
