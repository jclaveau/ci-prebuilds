#!/bin/bash
# Price a build on THIS machine, with instruction counts: browser-perf-record's
# candidate mode, or chromium-gap-probes' perf-record arm, run where a PMU
# exists. No hosted runner has passed one through (run 36242651767: 8
# attempts, five CPU models, all ENOENT), so on CI both report CPU-ms only.
#
#   playwright/bench/local-counted-compare.sh <chromium|firefox|webkit> <candidate_tag> <rev> [promoted_tag]
#   playwright/bench/local-counted-compare.sh <chromium|firefox|webkit> official [consumer_image]
#
# The first prices a candidate against promoted, both staged the way
# perf-gate.yml stages them. The second prices the shipped consumer image
# against Playwright's official one: the gap to parity, per kernel.
#
# Env: PERF_KERNELS (default layout_reflow,screenshot_png_text,js_alloc; for
# chromium vs official, one kernel per ratchet row), PERF_LOOP_SECONDS (200),
# PW_VERSION (1.62.1), LOCAL_CPUSET (0-3), LOCAL_MEMORY (6g),
# CANDIDATE_LD_PRELOAD (the candidate arm's LD_PRELOAD, unset by default).
# Output: tmp/counted-<candidate_tag or official-browser>/ and report.md there.
#
# Needs the PMU open to perf: Ubuntu's perf_event_paranoid=4 refuses it even
# to a privileged container. `sudo sysctl kernel.perf_event_paranoid=1` first.
set -euo pipefail

browser_name=$1
pw_version=${PW_VERSION:-1.62.1}
repo_root=$(git rev-parse --show-toplevel)
if [ "$2" = official ]; then
  case "$browser_name" in
    chromium|firefox|webkit) ;;
    *) echo "browser must be chromium, firefox or webkit" >&2; exit 2 ;;
  esac
  consumer_image=${3:-jclaveau/alpine-dood-playwright:latest}
  arm_names="alpine official"
  default_kernels=layout_reflow,screenshot_png_text,js_alloc
  [ "$browser_name" = chromium ] && \
    default_kernels=goto_warm,goto_cold,layout_reflow,layout_text,locator_click,js_alloc,eval_rtt,screenshot_png_text
  out_dir="$repo_root/tmp/counted-official-${browser_name}"
else
  candidate_tag=$2
  rev_number=$3
  case "$browser_name" in
    chromium) build_prefix=CHS; promoted_tag=${4:-chs-latest} ;;
    firefox)  build_prefix=FF; promoted_tag=${4:-ff-latest} ;;
    webkit)   build_prefix=WK; promoted_tag=${4:-wk-latest} ;;
    *) echo "browser must be chromium, firefox or webkit" >&2; exit 2 ;;
  esac
  arm_names="candidate promoted"
  default_kernels=layout_reflow,screenshot_png_text,js_alloc
  out_dir="$repo_root/tmp/counted-${candidate_tag}"
fi
kernel_list=${PERF_KERNELS:-$default_kernels}

cd "$repo_root"
python3 playwright/bench/pmu-check.py || {
  echo "no PMU open to perf here: sudo sysctl kernel.perf_event_paranoid=1" >&2
  exit 1
}
mkdir -p "$out_dir" && chmod 777 "$out_dir"
mkdir -p tmp/counted-symbols

if [ "$arm_names" = "alpine official" ]; then
  # The two images chromium-gap-probes' perf-record arm profiles, each with
  # its own distro's perf. Pulled, so a stale local tag is not the one priced;
  # a consumer variant built only here has nothing to pull and is used as is.
  official_image="mcr.microsoft.com/playwright:v${pw_version}-noble"
  docker pull -q "$consumer_image" 2>/dev/null \
    || docker image inspect "$consumer_image" >/dev/null
  docker pull -q "$official_image"
  docker build --build-arg "BASE=$consumer_image" \
    -t perf-alpine:counted -f playwright/bench/Dockerfile.perf-alpine playwright/bench
  docker build --build-arg "BASE=$official_image" \
    -t perf-official:counted -f playwright/bench/Dockerfile.perf-official playwright/bench
else
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
fi

# Interleaved per kernel, as in the workflow, so a machine that slows partway
# through does not land entirely on the second arm.
for kernel_name in $(echo "$kernel_list" | tr ',' ' '); do
  for arm_name in $arm_names; do
    perf_binary=perf
    [ "$arm_name" = official ] && perf_binary=/usr/local/bin/perf-real
    # CANDIDATE_LD_PRELOAD prices a container-wide preload on its own: pass
    # the promoted tag as the candidate too, and only this env differs.
    preload_env=()
    [ "$arm_name" = candidate ] && [ -n "${CANDIDATE_LD_PRELOAD:-}" ] && \
      preload_env=(--env "LD_PRELOAD=$CANDIDATE_LD_PRELOAD")
    docker run --rm --name "counted-${arm_name}-${kernel_name}" \
      --privileged --pid=host --user root \
      --cpuset-cpus "${LOCAL_CPUSET:-0-3}" --memory "${LOCAL_MEMORY:-6g}" \
      --security-opt seccomp=unconfined \
      --env HOME=/root \
      --env "PROBE_BROWSER=$browser_name" \
      --env "PROBE_TARGET=$arm_name" \
      --env "PROBE_KERNEL=$kernel_name" \
      --env "PW_VERSION=$pw_version" \
      --env "PERF_BIN=$perf_binary" \
      --env "PERF_LOOP_SECONDS=${PERF_LOOP_SECONDS:-200}" \
      --env "PERF_STRACE_STACKS=${PERF_STRACE_STACKS:-}" \
      --env "PERF_SYMBOLS_DIR=/symbols" \
      "${preload_env[@]}" \
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
PERF_RECORD_ARMS=$(echo "$arm_names" | tr ' ' ',') \
  python3 playwright/bench/perf-record-report.py "$out_dir" >| "$out_dir/report.md"
echo "=== DONE $out_dir/report.md"
