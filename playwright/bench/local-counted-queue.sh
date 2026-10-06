#!/bin/bash
# Run local-counted-compare.sh over a queue of candidates, one at a time: its
# counters are system-wide, so two counts at once spoil each other.
#
#   playwright/bench/local-counted-queue.sh <queue_file>
#
# One run per line, blank lines and # comments skipped:
#
#   <name> <browser> <candidate_tag> <kernels> [preload|-] [repeat]
#
#   cfi-icall-off chromium chs-fs-sha-a458fd3f… eval_rtt,goto_warm
#   node-mi       chromium chs-latest locator_click /usr/lib/libmimalloc-insecure.so.2
#   cfi-cold      chromium chs-fs-sha-a458fd3f… goto_cold - 3
#
# Each run lands in tmp/counted-<name>/ (tmp/counted-<name>-<i>/ when repeated),
# since the compare script always writes tmp/counted-<tag>/ and a second run on
# the same tag would overwrite the first.
#
# Before each run it waits for the 1-minute load average to drop under
# COUNTED_MAX_LOAD (default 2.0), and logs the load before and after, so a
# count taken on a busy box shows in the log. Ends with `=== DONE`.
set -uo pipefail

queue_file=$1
repo_root=$(git rev-parse --show-toplevel)
max_load=${COUNTED_MAX_LOAD:-2.0}
cd "$repo_root" || exit 1

load_now() { cut -d' ' -f1-3 /proc/loadavg; }
stamp_now() { date -u +%H:%M:%SZ; }

wait_for_quiet() {
  while awk -v max="$max_load" '{ exit !($1 >= max) }' /proc/loadavg; do
    echo "$(stamp_now) waiting, load=$(load_now) (max $max_load)"
    sleep 60
  done
}

# The browser's revision, from the consumer Dockerfile's defaults.
rev_for() {
  local arg_name
  case "$1" in
    chromium) arg_name=CHS_REV ;;
    firefox)  arg_name=FF_REV ;;
    webkit)   arg_name=WK_REV ;;
    *) echo "browser must be chromium, firefox or webkit" >&2; return 2 ;;
  esac
  sed -n "s/^ARG ${arg_name}=//p" playwright/Dockerfile.alpine | head -n 1
}

failed_count=0
while read -r run_name browser_name candidate_tag kernel_list preload_path repeat_count; do
  case "$run_name" in ''|'#'*) continue ;; esac
  [ "${preload_path:--}" = - ] && preload_path=
  repeat_count=${repeat_count:-1}
  rev_number=$(rev_for "$browser_name") || { failed_count=$((failed_count + 1)); continue; }

  for repeat_index in $(seq 1 "$repeat_count"); do
    out_name=$run_name
    [ "$repeat_count" -gt 1 ] && out_name="$run_name-$repeat_index"
    wait_for_quiet
    echo "$(stamp_now) start $out_name load=$(load_now)"
    PERF_KERNELS=$kernel_list CANDIDATE_LD_PRELOAD=$preload_path \
      playwright/bench/local-counted-compare.sh \
        "$browser_name" "$candidate_tag" "$rev_number" \
      >| "tmp/counted-$out_name.log" 2>&1 </dev/null
    run_rc=$?
    echo "$(stamp_now) end $out_name rc=$run_rc load=$(load_now)"
    [ "$run_rc" -ne 0 ] && failed_count=$((failed_count + 1))
    if [ "$out_name" != "$candidate_tag" ] && [ -d "tmp/counted-$candidate_tag" ]; then
      rm -rf "tmp/counted-$out_name"
      mv "tmp/counted-$candidate_tag" "tmp/counted-$out_name"
    fi
  done
done < "$queue_file"

echo "=== DONE failed=$failed_count"
