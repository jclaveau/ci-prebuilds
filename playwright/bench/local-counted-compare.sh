#!/bin/bash
# Price a candidate build against promoted on THIS machine, with instruction
# counts: browser-perf-record.yml's candidate mode, run where a PMU exists.
# No hosted runner has passed one through (run 36242651767: 8 attempts, five
# CPU models, all ENOENT), so on CI that workflow reports CPU-ms only.
#
#   playwright/bench/local-counted-compare.sh <firefox|webkit> <candidate_tag> <rev> [promoted_tag]
#
# Env: PERF_KERNELS (default layout_reflow,screenshot_png_text,js_alloc),
# PERF_LOOP_SECONDS (200), PW_VERSION (1.62.1), LOCAL_CPUSET (0-3),
# LOCAL_MEMORY (6g). Output: tmp/counted-<candidate_tag>/ and report.md there.
#
# Needs the PMU open to perf: Ubuntu's perf_event_paranoid=4 refuses it even
# to a privileged container. `sudo sysctl kernel.perf_event_paranoid=1` first.
set -euo pipefail

browser_name=$1
candidate_tag=$2
rev_number=$3
case "$browser_name" in
  firefox) build_prefix=FF; promoted_tag=${4:-ff-latest} ;;
  webkit)  build_prefix=WK; promoted_tag=${4:-wk-latest} ;;
  *) echo "browser must be firefox or webkit" >&2; exit 2 ;;
esac
kernel_list=${PERF_KERNELS:-layout_reflow,screenshot_png_text,js_alloc}
pw_version=${PW_VERSION:-1.62.1}
repo_root=$(git rev-parse --show-toplevel)
out_dir="$repo_root/tmp/counted-${candidate_tag}"

cd "$repo_root"
python3 playwright/bench/pmu-check.py || {
  echo "no PMU open to perf here: sudo sysctl kernel.perf_event_paranoid=1" >&2
  exit 1
}
mkdir -p "$out_dir" && chmod 777 "$out_dir"
mkdir -p tmp/counted-symbols

# The same staging as perf-gate.yml and the workflow's candidate mode.
for arm_name in candidate promoted; do
  arm_tag=$candidate_tag
  [ "$arm_name" = promoted ] && arm_tag=$promoted_tag
  docker build -f playwright/Dockerfile.alpine \
    --build-arg "BASE_IMAGE=ghcr.io/jclaveau/alpine-dood-pnpm:edge" \
    --build-arg "${build_prefix}_SOURCE_TAG=${arm_tag}" \
    --build-arg "${build_prefix}_REV=${rev_number}" \
    --build-arg "PLAYWRIGHT_VERSION=${pw_version}" \
    -t "stage-${arm_name}:counted" playwright
  docker build --build-arg "BASE=stage-${arm_name}:counted" \
    -t "perf-${arm_name}:counted" \
    -f playwright/bench/Dockerfile.perf-alpine playwright/bench
done

# Interleaved per kernel, as in the workflow, so a machine that slows partway
# through does not land entirely on the second arm.
for kernel_name in $(echo "$kernel_list" | tr ',' ' '); do
  for arm_name in candidate promoted; do
    docker run --rm --name "counted-${arm_name}-${kernel_name}" \
      --privileged --pid=host --user root \
      --cpuset-cpus "${LOCAL_CPUSET:-0-3}" --memory "${LOCAL_MEMORY:-6g}" \
      --security-opt seccomp=unconfined \
      --env HOME=/root \
      --env "PROBE_BROWSER=$browser_name" \
      --env "PROBE_TARGET=$arm_name" \
      --env "PROBE_KERNEL=$kernel_name" \
      --env "PW_VERSION=$pw_version" \
      --env "PERF_BIN=perf" \
      --env "PERF_LOOP_SECONDS=${PERF_LOOP_SECONDS:-200}" \
      --env "PERF_SYMBOLS_DIR=/symbols" \
      -v /sys/kernel/tracing:/sys/kernel/tracing:ro \
      -v /sys/kernel/debug:/sys/kernel/debug:ro \
      -v "$repo_root/playwright/bench:/probe:ro" \
      -v "$repo_root/playwright/scripts:/pwscripts:ro" \
      -v "$repo_root/tmp/counted-symbols:/symbols:ro" \
      -v "$out_dir:/out" \
      "perf-${arm_name}:counted" \
      sh -c '
        NODE_PATH="$(sh /pwscripts/global-node-path.sh)"
        export NODE_PATH
        node -e "require(\"playwright\")" 2>/dev/null \
          || npm install -g --no-fund --no-audit \
               "playwright@$PW_VERSION" >/dev/null 2>&1
        sh /probe/perf-profile.sh "$PROBE_TARGET" "$PROBE_KERNEL" \
           /out /probe/perf-kernel.cjs "$PERF_BIN"
      ' 2>&1 | tee "$out_dir/perfrec-${arm_name}-${kernel_name}.log" \
      || echo "${arm_name} / ${kernel_name} failed, see its log" >&2
  done
done

docker run --rm -v "$out_dir:/out" alpine chown -R "$(id -u):$(id -g)" /out
PERF_RECORD_ARMS=candidate,promoted \
  python3 playwright/bench/perf-record-report.py "$out_dir" >| "$out_dir/report.md"
echo "=== DONE $out_dir/report.md"
