#!/usr/bin/env bash
# pnpm-install-probe.sh: CPU cost of an offline `pnpm install` per arm, every arm
# on this one host, interleaved, one container per arm.
#
# An arm is `name=image|binary`. binary `image` runs the image's own pnpm, which
# is what pnpm-perf-gate measures; `<version>-<glibc|musl>` runs that native
# binary from the npm registry, so its libc and version vary apart from the
# image (the musl builds are static and run on the ubuntu image too).
#
# Counted from the container's own cgroup (cpu.stat user/system, memory.stat
# pgfault) around the install alone; the node_modules removal before it is a
# separate exec. The container is off the network for every counted install,
# so the store filled by the warm install is all pnpm can read. Writes
# runs.txt, and gate/<arm>-pnpm-run<N>.json for assert-perf-gate.py. Then one
# `strace -f -c` pass per arm, and a host `perf stat` pass when PERF_CMD is set.
#
# Env: WORK and OUT (required, absolute), ARMS, ROUNDS, CPUS, MEMORY, PNPM_OLD,
# PNPM_NEW, IMG_UBUNTU, IMG_ALPINE, FIXTURE_REPO, FIXTURE_SHA, PERF_CMD.
set -euo pipefail

: "${WORK:?WORK must name an empty scratch dir}" "${OUT:?OUT must name the results dir}"
ROUNDS=${ROUNDS:-5}
CPUS=${CPUS:-4}
MEMORY=${MEMORY:-6g}
PNPM_OLD=${PNPM_OLD:-12.6.0}
PNPM_NEW=${PNPM_NEW:-12.16.1}
IMG_UBUNTU=${IMG_UBUNTU:-ghcr.io/jclaveau/ubuntu-dood-pnpm-gyp:latest}
IMG_ALPINE=${IMG_ALPINE:-ghcr.io/jclaveau/alpine-dood-pnpm-gyp:latest}
FIXTURE_REPO=${FIXTURE_REPO:-https://github.com/vitest-dev/vitest}
FIXTURE_SHA=${FIXTURE_SHA:-da7ce1712fd4d0e4e807ec01ce755581e6892d5b}
PERF_CMD=${PERF_CMD:-}
ARMS=${ARMS:-"ubuntu-glibc-${PNPM_OLD}=${IMG_UBUNTU}|${PNPM_OLD}-glibc
alpine-musl-${PNPM_OLD}=${IMG_ALPINE}|${PNPM_OLD}-musl
ubuntu-musl-${PNPM_OLD}=${IMG_UBUNTU}|${PNPM_OLD}-musl
ubuntu-glibc-${PNPM_NEW}=${IMG_UBUNTU}|${PNPM_NEW}-glibc
alpine-musl-${PNPM_NEW}=${IMG_ALPINE}|${PNPM_NEW}-musl"}

read -r -a arm_specs <<<"${ARMS//$'\n'/ }"
arm_names=()
declare -A arm_image arm_binary
for arm_spec in "${arm_specs[@]}"; do
  arm_name=${arm_spec%%=*}
  arm_value=${arm_spec#*=}
  [[ "$arm_spec" == *=*'|'* ]] || { echo "arm spec '$arm_spec' is not name=image|binary" >&2; exit 1; }
  arm_names+=("$arm_name")
  arm_image[$arm_name]=${arm_value%|*}
  arm_binary[$arm_name]=${arm_value##*|}
done

mkdir -p "$WORK" "$OUT/gate"
{
  grep -m1 'model name' /proc/cpuinfo
  echo "nproc: $(nproc)"
  echo "kernel: $(uname -r)"
  echo "fixture: $FIXTURE_REPO@$FIXTURE_SHA"
  for arm_name in "${arm_names[@]}"; do
    echo "arm $arm_name image=${arm_image[$arm_name]} binary=${arm_binary[$arm_name]}"
  done
} | tee "$OUT/host.txt"

container_of() { echo "pip-$1"; }

cleanup_containers() {
  for arm_name in "${arm_names[@]}"; do
    container_name=$(container_of "$arm_name")
    if docker inspect "$container_name" >/dev/null 2>&1; then
      # The work tree is owned by the containers' uid 1001: remove it from inside.
      docker exec -u root "$container_name" sh -c 'rm -rf /w/fx /w/store /w/strace-*'
      docker rm -f "$container_name" >/dev/null
    fi
  done
}
trap cleanup_containers EXIT

binary_identity() {
  local binary_path=$1 mimalloc_strings
  mimalloc_strings=$(strings -n 8 "$binary_path" | awk '/mimalloc: /{count++} END{print count+0}')
  echo "sha256=$(sha256sum "$binary_path" | cut -c1-16) mimalloc_strings=${mimalloc_strings}"
}

fetch_binary() {
  local binary_name=$1 pnpm_version=${1%-*} libc_name=${1##*-} package_name=exe.linux-x64
  if [ "$libc_name" = musl ]; then package_name=exe.linux-x64-musl; fi
  local target_dir="$WORK/bins/$binary_name"
  [ -x "$target_dir/pnpm" ] && return 0
  mkdir -p "$target_dir"
  curl -fsSL "https://registry.npmjs.org/@pnpm/${package_name}/-/${package_name}-${pnpm_version}.tgz" \
    | tar -xzO package/pnpm >"$target_dir/pnpm"
  chmod 755 "$target_dir/pnpm"
  echo "binary $binary_name $(binary_identity "$target_dir/pnpm")" | tee -a "$OUT/host.txt"
}
mkdir -p "$WORK/bins"
for arm_name in "${arm_names[@]}"; do
  if [ "${arm_binary[$arm_name]}" != image ]; then fetch_binary "${arm_binary[$arm_name]}"; fi
done

pnpm_command() {
  if [ "${arm_binary[$1]}" = image ]; then echo pnpm; else echo "/bins/${arm_binary[$1]}/pnpm"; fi
}

# The fixture, pinned: packageManager stripped so the arm's binary is the one
# that runs, hoisted linker like the Planner, dependency builds skipped.
fixture_dir="$WORK/fixture"
if [ ! -f "$fixture_dir/package.json" ]; then
  git init -q "$fixture_dir"
  git -C "$fixture_dir" fetch -q --depth 1 "$FIXTURE_REPO" "$FIXTURE_SHA"
  git -C "$fixture_dir" checkout -q FETCH_HEAD
  rm -rf "$fixture_dir/.git"
  python3 - "$fixture_dir/package.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path))
manifest.pop('packageManager', None)
json.dump(manifest, open(path, 'w'), indent=2)
PY
  printf '\nnodeLinker: hoisted\nstrictDepBuilds: false\n' >>"$fixture_dir/pnpm-workspace.yaml"
fi
if grep -q packageManager "$fixture_dir/package.json"; then
  echo "fixture still pins packageManager: the image's pnpm would not be the one measured" >&2
  exit 1
fi

start_container() {
  local arm_name=$1 container_name
  container_name=$(container_of "$arm_name")
  mkdir -p "$WORK/$container_name"
  docker run -d --name "$container_name" --entrypoint sleep \
    --cpus="$CPUS" --memory="$MEMORY" \
    --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    -e HOME=/home/runner \
    -v "$WORK/$container_name:/w" -v "$WORK/bins:/bins:ro" -v "$fixture_dir:/fixture:ro" \
    "${arm_image[$arm_name]}" infinity >/dev/null
  # The store sits on the same mount as node_modules, so pnpm hardlinks from it.
  docker exec -u root "$container_name" sh -c '
    set -e
    rm -rf /w/fx /w/store && cp -r /fixture /w/fx && mkdir -p /w/store && chown -R 1001:1001 /w
    if command -v apk >/dev/null; then apk add -q strace >/dev/null
    else apt-get -qq update && apt-get -qq install -y strace >/dev/null; fi'
}
for arm_name in "${arm_names[@]}"; do start_container "$arm_name"; done

# Which pnpm each arm runs, read the way the install resolves it.
for arm_name in "${arm_names[@]}"; do
  container_name=$(container_of "$arm_name")
  pnpm_path=$(docker exec -u 1001 -w /w/fx "$container_name" sh -c \
    "readlink -f \"\$(command -v $(pnpm_command "$arm_name"))\"")
  pnpm_version=$(docker exec -u 1001 -w /w/fx "$container_name" "$(pnpm_command "$arm_name")" --version)
  docker cp -q "$container_name:$pnpm_path" "$WORK/pnpm-of-$arm_name"
  echo "pnpm $arm_name path=$pnpm_path version=$pnpm_version $(binary_identity "$WORK/pnpm-of-$arm_name")" \
    | tee -a "$OUT/host.txt"
  rm "$WORK/pnpm-of-$arm_name"
done

# Resolve the lockfile once, with the first arm's pnpm, then every arm installs
# that same lockfile frozen.
first_arm=${arm_names[0]}
docker exec -u 1001 -w /w/fx "$(container_of "$first_arm")" "$(pnpm_command "$first_arm")" install \
  --no-frozen-lockfile --store-dir=/w/store >"$OUT/resolve.log" 2>&1 || { tail -30 "$OUT/resolve.log"; exit 1; }
docker cp -q "$(container_of "$first_arm"):/w/fx/pnpm-lock.yaml" "$OUT/pnpm-lock.yaml"
for arm_name in "${arm_names[@]:1}"; do
  docker cp -q "$OUT/pnpm-lock.yaml" "$(container_of "$arm_name"):/w/fx/pnpm-lock.yaml"
  docker exec -u root "$(container_of "$arm_name")" chown 1001:1001 /w/fx/pnpm-lock.yaml
done
echo "lockfile sha256=$(sha256sum "$OUT/pnpm-lock.yaml" | cut -c1-16)" | tee -a "$OUT/host.txt"

remove_node_modules() {
  docker exec -u 1001 -w /w/fx "$(container_of "$1")" sh -c 'find . -name node_modules -type d -prune -exec rm -rf {} +'
}

run_install() {
  local arm_name=$1 log_file=$2
  shift 2
  docker exec -u 1001 -w /w/fx "$(container_of "$arm_name")" "$@" "$(pnpm_command "$arm_name")" install \
    --frozen-lockfile --offline --store-dir=/w/store >"$log_file" 2>&1
}

# Warm every arm online once: fills its store, and proves its pnpm installs the
# shared lockfile before any count is taken.
for arm_name in "${arm_names[@]}"; do
  container_name=$(container_of "$arm_name")
  remove_node_modules "$arm_name"
  docker exec -u 1001 -w /w/fx "$container_name" "$(pnpm_command "$arm_name")" install \
    --frozen-lockfile --store-dir=/w/store >"$OUT/warm-$arm_name.log" 2>&1 \
    || { echo "warm install failed for $arm_name" >&2; tail -30 "$OUT/warm-$arm_name.log"; exit 1; }
  file_count=$(docker exec "$container_name" sh -c 'find /w/fx -path "*/node_modules/*" -type f | wc -l')
  echo "warm $arm_name node_modules_files=$file_count" | tee -a "$OUT/host.txt"
  docker network disconnect bridge "$container_name"
done

read_counters() {
  docker exec "$(container_of "$1")" sh -c 'cat /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.stat' \
    | awk '/^(user_usec|system_usec|pgfault|pgmajfault) /{printf "%s=%s ", $1, $2}'
}

counter_value() {
  local counter_line=$1 counter_name=$2
  sed -n "s/.*\b${counter_name}=\([0-9]*\).*/\1/p" <<<"$counter_line"
}

: >"$OUT/runs.txt"
arm_count=${#arm_names[@]}
for round in $(seq 1 "$ROUNDS"); do
  for offset in $(seq 0 $((arm_count - 1))); do
    arm_name=${arm_names[$(((round + offset) % arm_count))]}
    remove_node_modules "$arm_name"
    counters_before=$(read_counters "$arm_name")
    start_ns=$(date +%s%N)
    install_rc=0
    run_install "$arm_name" "$OUT/install-$arm_name-$round.log" || install_rc=$?
    wall_ms=$((($(date +%s%N) - start_ns) / 1000000))
    counters_after=$(read_counters "$arm_name")
    echo "round=$round arm=$arm_name rc=$install_rc wall_ms=$wall_ms before: $counters_before after: $counters_after" \
      | tee -a "$OUT/runs.txt"
    if [ "$install_rc" != 0 ]; then
      echo "install failed: $arm_name round $round" >&2
      tail -30 "$OUT/install-$arm_name-$round.log" >&2
      exit 1
    fi
    user_us=$(($(counter_value "$counters_after" user_usec) - $(counter_value "$counters_before" user_usec)))
    sys_us=$(($(counter_value "$counters_after" system_usec) - $(counter_value "$counters_before" system_usec)))
    printf '{"arm":"%s","round":%d,"metrics":{"install_cpu":{"median_ms":%.3f},"install_sys":{"median_ms":%.3f},"install_user":{"median_ms":%.3f}}}\n' \
      "$arm_name" "$round" "$(((user_us + sys_us)))e-3" "${sys_us}e-3" "${user_us}e-3" \
      >"$OUT/gate/$arm_name-pnpm-run$round.json"
  done
done

for arm_name in "${arm_names[@]}"; do
  container_name=$(container_of "$arm_name")
  remove_node_modules "$arm_name"
  run_install "$arm_name" "$OUT/strace-install-$arm_name.log" strace -f -c -o "/w/strace-$arm_name.txt"
  docker cp -q "$container_name:/w/strace-$arm_name.txt" "$OUT/strace-$arm_name.txt"
done

if [ -n "$PERF_CMD" ]; then
  perf_events=task-clock,page-faults,minor-faults,major-faults,context-switches,cpu-migrations
  for arm_name in "${arm_names[@]}"; do
    container_name=$(container_of "$arm_name")
    container_pid=$(docker inspect -f '{{.State.Pid}}' "$container_name")
    cgroup_path=$(sed -n 's/^0:://p' "/proc/$container_pid/cgroup")
    # perf wants every -e before -G, and one -G entry per event.
    cgroup_list=$(printf "${cgroup_path#/},%.0s" 1 2 3 4 5 6)
    remove_node_modules "$arm_name"
    $PERF_CMD stat -a -e "$perf_events" -G "${cgroup_list%,}" -o "$OUT/perf-$arm_name.txt" -- \
      docker exec -u 1001 -w /w/fx "$container_name" "$(pnpm_command "$arm_name")" install \
      --frozen-lockfile --offline --store-dir=/w/store >"$OUT/perf-install-$arm_name.log" 2>&1 \
      || { echo "perf stat failed for $arm_name" >&2; tail -30 "$OUT/perf-install-$arm_name.log" >&2; exit 1; }
  done
fi
echo "=== DONE ===" | tee -a "$OUT/runs.txt"
