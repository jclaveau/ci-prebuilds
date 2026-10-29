#!/usr/bin/env bash
# Host side of wk-mixed-launch-probe.yml. Every arm is a long-lived container
# named after the arm (started by the workflow); this execs the probe in it.
#
#   wk-mixed-launch-run.sh measure <arm> <round>   timed launches + perf stat
#   wk-mixed-launch-run.sh diag <arm>              strace / DEBUG / --cpu-prof
#   wk-mixed-launch-run.sh record <arm>            perf record of node
#
# OUT (host dir, mounted at /out), PERF (host perf binary), HAS_PMU (0|1),
# LAUNCH_COUNT and WARM_COUNT come from the environment.
set -euo pipefail

: "${OUT:?}" "${PERF:?}" "${HAS_PMU:?}"
LAUNCH_COUNT=${LAUNCH_COUNT:-10}
WARM_COUNT=${WARM_COUNT:-3}
PROBE=/s/wk-mixed-launch-probe.cjs

# The official image has no runner user and keeps its browsers in
# /ms-playwright (its own ENV); every ubuntu-dood arm runs as runner.
exec_identity() {
  case "$1" in
    official) echo "-u 0" ;;
    u26*|u24*)
      echo "-u runner -e HOME=/home/runner -e PLAYWRIGHT_BROWSERS_PATH=/home/runner/playwright-browsers" ;;
    *) echo "unknown arm: $1" >&2; exit 2 ;;
  esac
}

arm_exec() {
  local arm=$1; shift
  # shellcheck disable=SC2046
  docker exec $(exec_identity "$arm") -e NODE_PATH=/nm -e ARM_NAME="$arm" \
    -e LAUNCH_COUNT -e WARM_COUNT "$@"
}

# The probe runs in the background of THIS shell (so `wait` can reap it); it
# prints `ready <nspid>` once warm, then waits for its GO_FILE.
# Sets PROBE_EXEC_PID, GO_FILE_PATH.
start_waiting_probe() {
  local arm=$1 log_file=$2; shift 2
  GO_FILE_PATH="/tmp/go-$arm-$RANDOM$RANDOM"
  arm_exec "$arm" -e GO_FILE="$GO_FILE_PATH" "$arm" "$@" > "$log_file" 2>&1 &
  PROBE_EXEC_PID=$!
}

# Sets NS_PID, HOST_PID, CGROUP_REL once the probe is ready.
resolve_probe_pids() {
  local arm=$1 log_file=$2 wait_index candidate_pid container_pid
  NS_PID=""
  for wait_index in $(seq 1 1200); do
    NS_PID=$(sed -n 's/^ready \([0-9]*\)$/\1/p' "$log_file" | head -1)
    [ -n "$NS_PID" ] && break
    kill -0 "$PROBE_EXEC_PID" 2>/dev/null \
      || { echo "probe died before ready ($arm):" >&2; cat "$log_file" >&2; exit 1; }
    sleep 0.1
  done
  [ -n "$NS_PID" ] || { echo "no ready line from $arm in 120 s" >&2; exit 1; }
  container_pid=$(docker inspect -f '{{.State.Pid}}' "$arm")
  CGROUP_REL=$(sed -n 's/^0::\///p' "/proc/$container_pid/cgroup")
  HOST_PID=""
  for candidate_pid in $(cat "/sys/fs/cgroup/$CGROUP_REL/cgroup.procs"); do
    if [ "$(awk '/^NSpid/ { print $NF }' "/proc/$candidate_pid/status" 2>/dev/null)" = "$NS_PID" ]; then
      HOST_PID=$candidate_pid
    fi
  done
  [ -n "$HOST_PID" ] || { echo "no host pid for $arm nspid $NS_PID" >&2; exit 1; }
}

finish_probe() {
  local arm=$1 log_file=$2
  docker exec -u 0 "$arm" touch "$GO_FILE_PATH"
  wait "$PROBE_EXEC_PID" && return 0
  echo "probe failed ($arm):" >&2
  cat "$log_file" >&2
  return 1
}

stat_events() {
  if [ "$HAS_PMU" = 1 ]; then echo task-clock,instructions,cycles
  else echo task-clock; fi
}

measure() {
  local arm=$1 round_index=$2
  local log_file="$OUT/raw/$arm-r$round_index.log"
  start_waiting_probe "$arm" "$log_file" node "$PROBE"
  resolve_probe_pids "$arm" "$log_file"
  # node alone (--no-inherit), and the whole container cgroup beside it.
  sudo "$PERF" stat -x, --no-inherit -e "$(stat_events)" -p "$HOST_PID" \
    -o "$OUT/raw/$arm-r$round_index.node.perfstat" &
  local node_stat_pid=$!
  sudo "$PERF" stat -x, -a -e "$(stat_events)" -G "$CGROUP_REL" \
    -o "$OUT/raw/$arm-r$round_index.cgroup.perfstat" &
  local cgroup_stat_pid=$!
  sleep 0.5
  local probe_status=0
  finish_probe "$arm" "$log_file" || probe_status=$?
  # The system-wide stat never ends on its own; stop it on every path.
  sudo pkill -INT -P "$cgroup_stat_pid" 2>/dev/null || true
  wait "$node_stat_pid" "$cgroup_stat_pid" || true
  [ "$probe_status" = 0 ] || exit 1
  grep '^{' "$log_file" >> "$OUT/$arm.jsonl"
}

diag() {
  local arm=$1
  local diag_env=(-e LAUNCH_COUNT=3 -e WARM_COUNT=1)
  arm_exec "$arm" "${diag_env[@]}" "$arm" strace -f -c -o "/out/diag/$arm.strace-fc.txt" node "$PROBE" > /dev/null
  arm_exec "$arm" "${diag_env[@]}" "$arm" strace -c -o "/out/diag/$arm.strace-c-node.txt" node "$PROBE" > /dev/null
  arm_exec "$arm" "${diag_env[@]}" "$arm" strace -f -qq -s 300 -e trace=execve \
    -o "/out/diag/$arm.execve.txt" node "$PROBE" > /dev/null
  arm_exec "$arm" "${diag_env[@]}" -e DEBUG='pw:browser*,pw:protocol' "$arm" \
    node "$PROBE" > "$OUT/diag/$arm.debug.txt" 2>&1
  arm_exec "$arm" -e LAUNCH_COUNT=10 -e WARM_COUNT=3 "$arm" \
    node --cpu-prof --cpu-prof-dir="/out/diag/cpuprof-$arm" "$PROBE" > /dev/null
}

record() {
  local arm=$1
  local log_file="$OUT/raw/$arm-record.log"
  start_waiting_probe "$arm" "$log_file" node --perf-basic-prof "$PROBE"
  resolve_probe_pids "$arm" "$log_file"
  sudo "$PERF" record -g --no-inherit -F 999 -p "$HOST_PID" \
    -o "$OUT/diag/$arm.perf.data" 2> "$OUT/diag/$arm.perf-record.err" &
  local record_pid=$!
  sleep 0.5
  finish_probe "$arm" "$log_file" || exit 1
  wait "$record_pid" || true
  sudo chown -R "$(id -u):$(id -g)" "$OUT/diag"
  # The JIT map is written inside the container under its own pid; perf looks
  # it up under the host pid. /tmp is a tmpfs, which docker cp cannot read.
  # The node binary and libc go into a symfs.
  local symfs_dir="$OUT/diag/symfs-$arm" node_path
  node_path=$(docker exec "$arm" sh -c 'readlink -f "$(command -v node)"')
  mkdir -p "$symfs_dir/tmp" "$symfs_dir$(dirname "$node_path")" "$symfs_dir/usr/lib/x86_64-linux-gnu"
  docker exec "$arm" cat "/tmp/perf-$NS_PID.map" > "/tmp/perf-$HOST_PID.map"
  cp "/tmp/perf-$HOST_PID.map" "$symfs_dir/tmp/perf-$HOST_PID.map"
  docker cp "$arm:$node_path" "$symfs_dir$node_path"
  docker cp -L "$arm:/usr/lib/x86_64-linux-gnu/libc.so.6" "$symfs_dir/usr/lib/x86_64-linux-gnu/libc.so.6"
  # Full reports to files first: piping perf into head SIGPIPEs it under pipefail.
  "$PERF" report -i "$OUT/diag/$arm.perf.data" --symfs "$symfs_dir" --no-children \
    --sort dso,sym --stdio > "$OUT/diag/$arm.perf-report-full.txt" 2>/dev/null
  "$PERF" report -i "$OUT/diag/$arm.perf.data" --no-children --sort dso --stdio \
    > "$OUT/diag/$arm.perf-dso-full.txt" 2>/dev/null
  grep -v '^$' "$OUT/diag/$arm.perf-report-full.txt" | sed -n 1,70p > "$OUT/diag/$arm.perf-report.txt"
  grep -v -e '^#' -e '^$' "$OUT/diag/$arm.perf-dso-full.txt" | sed -n 1,15p > "$OUT/diag/$arm.perf-dso.txt"
}

mkdir -p "$OUT/raw" "$OUT/diag"
case "${1:-}" in
  measure) measure "$2" "$3" ;;
  diag) diag "$2" ;;
  record) record "$2" ;;
  *) echo "usage: $0 measure <arm> <round> | diag <arm> | record <arm>" >&2; exit 2 ;;
esac
