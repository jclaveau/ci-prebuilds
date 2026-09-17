#!/usr/bin/env bash
# Cold `docker pull` timings for a set of image refs, bracketed: the pull
# order is reversed every other round so a bandwidth drift across the job
# cancels instead of landing on one image. `-c "3 8"` repeats the whole set
# under each daemon `max-concurrent-downloads` value (restarts dockerd — CI
# runners only). `-p` prunes every local image first so nothing is warm.
#
#   scripts/image-pull-bench.sh [-p] [-r ROUNDS] [-c "3 8"] IMAGE...
#
# Prints a markdown table (also appended to $GITHUB_STEP_SUMMARY when set).
set -euo pipefail

ROUNDS=3
CONC=""
PRUNE=0
while getopts pr:c: o; do
  case $o in
    p) PRUNE=1 ;;
    r) ROUNDS=$OPTARG ;;
    c) CONC=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
(( $# )) || { echo "usage: $0 [-p] [-r ROUNDS] [-c \"3 8\"] IMAGE..." >&2; exit 2; }
IMAGES=("$@")

set_concurrency() {
  sudo mkdir -p /etc/docker
  sudo python3 - "$1" <<'PY'
import json, os, sys
p = '/etc/docker/daemon.json'
d = json.load(open(p)) if os.path.exists(p) else {}
d['max-concurrent-downloads'] = int(sys.argv[1])
open(p, 'w').write(json.dumps(d))
PY
  sudo systemctl restart docker
}

# layers + compressed bytes of the linux/amd64 manifest
layer_stats() {
  docker manifest inspect "$1" | python3 -c '
import json, sys
m = json.load(sys.stdin)
if "manifests" in m:
    ref = sys.argv[1].split("@")[0].rsplit(":", 1)[0]
    d = [x["digest"] for x in m["manifests"] if x["platform"].get("os") == "linux"][0]
    import subprocess
    m = json.loads(subprocess.check_output(["docker", "manifest", "inspect", f"{ref}@{d}"]))
ls = m["layers"]
print(len(ls), round(sum(l["size"] for l in ls) / 2**20, 1))' "$1"
}

# every bench image goes, not just the one about to be pulled: the refs
# share most of their layers, and a layer left behind by the previous pull
# would make this one warm
timed_pull() {
  docker rmi -f "${IMAGES[@]}" >/dev/null 2>&1 || true
  docker image prune -f >/dev/null
  local t0 t1
  t0=$(date +%s.%N)
  docker pull -q "$1" >/dev/null
  t1=$(date +%s.%N)
  python3 -c "print(round($t1 - $t0, 1))"
}

median() { python3 -c 'import sys,statistics; print(round(statistics.median(map(float, sys.argv[1:])), 1))' "$@"; }

(( PRUNE )) && docker system prune -af >/dev/null

declare -A STATS
for img in "${IMAGES[@]}"; do STATS[$img]=$(layer_stats "$img"); done

OUT="| image | layers | gz MiB | max-concurrent-downloads | pulls (s) | median (s) |
|---|---|---|---|---|---|"
for c in ${CONC:-current}; do
  [[ $c == current ]] || set_concurrency "$c"
  declare -A T=()
  for ((r = 0; r < ROUNDS; r++)); do
    order=("${IMAGES[@]}")
    (( r % 2 )) && mapfile -t order < <(printf '%s\n' "${IMAGES[@]}" | tac)
    for img in "${order[@]}"; do
      s=$(timed_pull "$img")
      echo "round $r  conc=$c  ${s}s  $img" >&2
      T[$img]+="$s "
    done
  done
  for img in "${IMAGES[@]}"; do
    read -r layers mib <<<"${STATS[$img]}"
    # shellcheck disable=SC2086
    OUT+="
| \`$img\` | $layers | $mib | $c | ${T[$img]% } | $(median ${T[$img]}) |"
  done
done

echo "$OUT"
[[ -n ${GITHUB_STEP_SUMMARY:-} ]] && echo "$OUT" >> "$GITHUB_STEP_SUMMARY"
exit 0
