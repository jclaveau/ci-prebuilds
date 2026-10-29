#!/usr/bin/env bash
# pnpm-install-probe.sh: CPU cost of an offline `pnpm install` per arm, every arm
# on this one host, interleaved. An arm is an image plus a pnpm native binary
# fetched from the npm registry, so the binary's libc and version vary apart
# from the image: the musl binaries are static, they run on the ubuntu image too.
#
# Counted from the container's own cgroup (cpu.stat user/system, memory.stat
# pgfault) around the install alone; the node_modules removal before it is a
# separate exec. One `strace -f -c` pass per arm follows the timed rounds, and a
# host `perf stat` pass when PERF_CMD is set and works.
#
# Env: WORK and OUT (required, absolute), ROUNDS, CPUS, MEMORY, PNPM_OLD,
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

# arm = container:libc:version
ARM_SPECS=(
  "ubuntu-glibc-${PNPM_OLD}=pip-ubuntu:glibc:${PNPM_OLD}"
  "alpine-musl-${PNPM_OLD}=pip-alpine:musl:${PNPM_OLD}"
  "ubuntu-musl-${PNPM_OLD}=pip-ubuntu:musl:${PNPM_OLD}"
  "ubuntu-glibc-${PNPM_NEW}=pip-ubuntu:glibc:${PNPM_NEW}"
  "alpine-musl-${PNPM_NEW}=pip-alpine:musl:${PNPM_NEW}"
)

mkdir -p "$WORK" "$OUT"
{
  grep -m1 'model name' /proc/cpuinfo || echo "model name: unknown"
  echo "nproc: $(nproc)"
  echo "kernel: $(uname -r)"
  echo "fixture: $FIXTURE_REPO@$FIXTURE_SHA"
  echo "images: ubuntu=$IMG_UBUNTU alpine=$IMG_ALPINE"
} | tee "$OUT/host.txt"

cleanup_containers() {
  for container_name in pip-ubuntu pip-alpine; do
    # The work tree is owned by the containers' uid 1001: remove it from inside.
    docker exec -u root "$container_name" sh -c 'rm -rf /w/fx /w/store' >/dev/null 2>&1 || true
    docker rm -f "$container_name" >/dev/null 2>&1 || true
  done
}
trap cleanup_containers EXIT

fetch_binary() {
  local libc_name=$1 pnpm_version=$2 package_name
  package_name=exe.linux-x64$([ "$libc_name" = musl ] && echo -musl)
  local target_dir="$WORK/bins/${pnpm_version}-${libc_name}"
  [ -x "$target_dir/pnpm" ] && return 0
  mkdir -p "$target_dir"
  curl -fsSL "https://registry.npmjs.org/@pnpm/${package_name}/-/${package_name}-${pnpm_version}.tgz" \
    | tar -xzO package/pnpm >"$target_dir/pnpm"
  chmod 755 "$target_dir/pnpm"
  local mimalloc_strings
  mimalloc_strings=$(strings -n 8 "$target_dir/pnpm" | grep -c 'mimalloc: ' || true)
  echo "binary ${pnpm_version}-${libc_name} sha256=$(sha256sum "$target_dir/pnpm" | cut -c1-16)" \
    "mimalloc_strings=${mimalloc_strings}" | tee -a "$OUT/host.txt"
}
for pnpm_version in "$PNPM_OLD" "$PNPM_NEW"; do
  fetch_binary glibc "$pnpm_version"
  fetch_binary musl "$pnpm_version"
done

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

start_container() {
  local container_name=$1 image_name=$2
  mkdir -p "$WORK/$container_name"
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  docker run -d --name "$container_name" --entrypoint sleep \
    --cpus="$CPUS" --memory="$MEMORY" \
    --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    -e HOME=/home/runner \
    -v "$WORK/$container_name:/w" -v "$WORK/bins:/bins:ro" -v "$fixture_dir:/fixture:ro" \
    "$image_name" infinity >/dev/null
  # The store sits on the same mount as node_modules, so pnpm hardlinks from it.
  docker exec -u root "$container_name" sh -c '
    rm -rf /w/fx /w/store && cp -r /fixture /w/fx && mkdir -p /w/store && chown -R 1001:1001 /w
    apk add -q strace >/dev/null 2>&1 || { apt-get -qq update && apt-get -qq install -y strace; } >/dev/null 2>&1
    command -v strace >/dev/null || { echo "strace did not install" >&2; exit 1; }'
}
start_container pip-ubuntu "$IMG_UBUNTU"
start_container pip-alpine "$IMG_ALPINE"

# Resolve the lockfile once, with the OLD glibc binary (newer pnpm reads it),
# then every arm installs that same lockfile frozen.
docker exec -u 1001 -w /w/fx pip-ubuntu "/bins/${PNPM_OLD}-glibc/pnpm" install --no-frozen-lockfile \
  --store-dir=/w/store >"$OUT/resolve.log" 2>&1 || { tail -30 "$OUT/resolve.log"; exit 1; }
docker cp pip-ubuntu:/w/fx/pnpm-lock.yaml "$OUT/pnpm-lock.yaml"
docker cp "$OUT/pnpm-lock.yaml" pip-alpine:/w/fx/pnpm-lock.yaml
docker exec -u root pip-alpine chown 1001:1001 /w/fx/pnpm-lock.yaml
echo "lockfile sha256=$(sha256sum "$OUT/pnpm-lock.yaml" | cut -c1-16)" | tee -a "$OUT/host.txt"

remove_node_modules() {
  docker exec -u 1001 -w /w/fx "$1" sh -c 'find . -name node_modules -type d -prune -exec rm -rf {} +'
}

run_install() {
  local container_name=$1 binary_dir=$2 log_file=$3
  shift 3
  docker exec -u 1001 -w /w/fx "$container_name" "$@" "/bins/$binary_dir/pnpm" install \
    --frozen-lockfile --offline --store-dir=/w/store >"$log_file" 2>&1
}

# Warm every (container, binary) pair online once: fills the store, and proves
# each binary installs the shared lockfile before any count is taken.
for arm_spec in "${ARM_SPECS[@]}"; do
  arm_name=${arm_spec%%=*}
  IFS=: read -r container_name libc_name pnpm_version <<<"${arm_spec#*=}"
  remove_node_modules "$container_name"
  docker exec -u 1001 -w /w/fx "$container_name" "/bins/${pnpm_version}-${libc_name}/pnpm" install \
    --frozen-lockfile --store-dir=/w/store >"$OUT/warm-$arm_name.log" 2>&1 \
    || { echo "warm install failed for $arm_name" >&2; tail -30 "$OUT/warm-$arm_name.log"; exit 1; }
  file_count=$(docker exec "$container_name" sh -c 'find /w/fx -path "*/node_modules/*" -type f | wc -l')
  echo "warm $arm_name node_modules_files=$file_count" | tee -a "$OUT/host.txt"
done

read_counters() {
  docker exec "$1" sh -c 'cat /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.stat' \
    | awk '/^(user_usec|system_usec|pgfault|pgmajfault) /{printf "%s=%s ", $1, $2}'
}

: >"$OUT/runs.txt"
arm_count=${#ARM_SPECS[@]}
for round in $(seq 1 "$ROUNDS"); do
  for offset in $(seq 0 $((arm_count - 1))); do
    arm_spec=${ARM_SPECS[$(((round + offset) % arm_count))]}
    arm_name=${arm_spec%%=*}
    IFS=: read -r container_name libc_name pnpm_version <<<"${arm_spec#*=}"
    remove_node_modules "$container_name"
    counters_before=$(read_counters "$container_name")
    start_ns=$(date +%s%N)
    install_rc=0
    run_install "$container_name" "${pnpm_version}-${libc_name}" "$OUT/install-$arm_name-$round.log" \
      || install_rc=$?
    wall_ms=$((($(date +%s%N) - start_ns) / 1000000))
    counters_after=$(read_counters "$container_name")
    line="round=$round arm=$arm_name rc=$install_rc wall_ms=$wall_ms before: $counters_before after: $counters_after"
    echo "$line" | tee -a "$OUT/runs.txt"
    [ "$install_rc" = 0 ] || { echo "install failed: $arm_name round $round" >&2; exit 1; }
  done
done

for arm_spec in "${ARM_SPECS[@]}"; do
  arm_name=${arm_spec%%=*}
  IFS=: read -r container_name libc_name pnpm_version <<<"${arm_spec#*=}"
  remove_node_modules "$container_name"
  run_install "$container_name" "${pnpm_version}-${libc_name}" "$OUT/strace-install-$arm_name.log" \
    strace -f -c -o "/w/strace-$arm_name.txt"
  docker cp "$container_name:/w/strace-$arm_name.txt" "$OUT/strace-$arm_name.txt"
done

if [ -n "$PERF_CMD" ]; then
  if $PERF_CMD stat -e page-faults -- true >/dev/null 2>&1; then
    for arm_spec in "${ARM_SPECS[@]}"; do
      arm_name=${arm_spec%%=*}
      IFS=: read -r container_name libc_name pnpm_version <<<"${arm_spec#*=}"
      container_pid=$(docker inspect -f '{{.State.Pid}}' "$container_name")
      cgroup_path=$(sed -n 's/^0:://p' "/proc/$container_pid/cgroup")
      remove_node_modules "$container_name"
      $PERF_CMD stat -a -G "${cgroup_path#/}" \
        -e task-clock,page-faults,minor-faults,major-faults,context-switches,cpu-migrations \
        -o "$OUT/perf-$arm_name.txt" -- \
        docker exec -u 1001 -w /w/fx "$container_name" "/bins/${pnpm_version}-${libc_name}/pnpm" install \
        --frozen-lockfile --offline --store-dir=/w/store >"$OUT/perf-install-$arm_name.log" 2>&1
    done
  else
    echo "perf unavailable: '$PERF_CMD stat -e page-faults -- true' failed" | tee -a "$OUT/host.txt"
  fi
fi
echo "=== DONE ===" | tee -a "$OUT/runs.txt"
