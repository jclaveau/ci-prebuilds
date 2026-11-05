#!/usr/bin/env bash
# pnpm-install-probe.sh: CPU cost of an offline `pnpm install` per arm, every arm
# on this one host, interleaved, one container per arm.
#
# An arm is `name=image|binary[|VAR=value]`. binary `image` runs the image's own
# pnpm, which is what pnpm-perf-gate measures; `<version>-<glibc|musl>` runs that
# native binary from the npm registry, so its libc and version vary apart from
# the image (the musl builds are static and run on the ubuntu image too). The
# optional third field is one environment variable set on every install.
#
# By default an arm's store and project share the /w bind mount, so pnpm
# hardlinks. Two image forms bake the store into an image layer instead, built
# on the named arm's image from the store its warm install filled:
#   store-layer:<arm>  store at /opt/store in the image, project on /w.
#   deps-layer:<arm>   store at /opt/store plus the project installed at /app
#                      in the image, so the counted install finds node_modules.
#   modules-layer:<arm> the project installed at /app with the store mounted
#                      only at build time: node_modules ships, the store does
#                      not (/opt/store is empty). If its warm install fails,
#                      the arm is dropped and host.txt says so.
#   onerun-layer:<arm> the deps-image shape: the named arm's store mounted as a
#                      seed, copied to /opt/store and installed at /app in ONE
#                      RUN, then `pnpm store prune`, so node_modules and the
#                      store share inodes in one layer.
#   linked-layer:<arm> the onerun-layer image with the project on /w, each of
#                      its node_modules a symlink to the one under /app (a
#                      checkout outside the image). Dropped like modules-layer
#                      if its warm install or its require check fails.
# A layered arm gets a fresh container (no network) before every install, so
# no install starts from an overlay that an earlier one already copied up.
#
# Counted from the container's own cgroup (cpu.stat user/system, memory.stat
# pgfault) around the install alone; the node_modules removal before it is a
# separate exec. The container is off the network for every counted install,
# so the store filled by the warm install is all pnpm can read. Writes
# runs.txt, and gate/<arm>-pnpm-run<N>.json for assert-perf-gate.py. Then
# STRACE_ROUNDS interleaved `strace -f -c` passes per arm, a stat-family path
# trace for each arm named in STRACE_PATH_ARMS, and a host `perf stat` pass when
# PERF_CMD is set.
#
# Env: WORK and OUT (required, absolute), ARMS, ROUNDS, STRACE_ROUNDS,
# STRACE_PATH_ARMS, CPUS, MEMORY, PNPM_OLD, PNPM_NEW, IMG_UBUNTU, IMG_ALPINE,
# FIXTURE_REPO, FIXTURE_SHA, PERF_CMD, STORE_EXPORT_ARM (copies that arm's
# store and metadata cache to $WORK/export).
set -euo pipefail

: "${WORK:?WORK must name an empty scratch dir}" "${OUT:?OUT must name the results dir}"
ROUNDS=${ROUNDS:-5}
STRACE_ROUNDS=${STRACE_ROUNDS:-1}
STRACE_PATH_ARMS=${STRACE_PATH_ARMS:-}
CPUS=${CPUS:-4}
MEMORY=${MEMORY:-6g}
PNPM_OLD=${PNPM_OLD:-12.6.0}
PNPM_NEW=${PNPM_NEW:-12.16.1}
IMG_UBUNTU=${IMG_UBUNTU:-ghcr.io/jclaveau/ubuntu-dood-pnpm-gyp:latest}
IMG_ALPINE=${IMG_ALPINE:-ghcr.io/jclaveau/alpine-dood-pnpm-gyp:latest}
FIXTURE_REPO=${FIXTURE_REPO:-https://github.com/vitest-dev/vitest}
FIXTURE_SHA=${FIXTURE_SHA:-da7ce1712fd4d0e4e807ec01ce755581e6892d5b}
PERF_CMD=${PERF_CMD:-}
STORE_EXPORT_ARM=${STORE_EXPORT_ARM:-}
ARMS=${ARMS:-"ubuntu-glibc-${PNPM_OLD}=${IMG_UBUNTU}|${PNPM_OLD}-glibc
alpine-musl-${PNPM_OLD}=${IMG_ALPINE}|${PNPM_OLD}-musl
ubuntu-musl-${PNPM_OLD}=${IMG_UBUNTU}|${PNPM_OLD}-musl
ubuntu-glibc-${PNPM_NEW}=${IMG_UBUNTU}|${PNPM_NEW}-glibc
alpine-musl-${PNPM_NEW}=${IMG_ALPINE}|${PNPM_NEW}-musl"}

read -r -a arm_specs <<<"${ARMS//$'\n'/ }"
arm_names=()
declare -A arm_image arm_binary arm_env
for arm_spec in "${arm_specs[@]}"; do
  arm_name=${arm_spec%%=*}
  arm_value=${arm_spec#*=}
  [[ "$arm_spec" == *=*'|'* ]] || { echo "arm spec '$arm_spec' is not name=image|binary[|VAR=value]" >&2; exit 1; }
  IFS='|' read -r spec_image spec_binary spec_env <<<"$arm_value"
  if [ -n "$spec_env" ] && [[ "$spec_env" != [A-Za-z_]*=* ]]; then
    echo "arm spec '$arm_spec': third field '$spec_env' is not VAR=value" >&2; exit 1
  fi
  arm_names+=("$arm_name")
  arm_image[$arm_name]=$spec_image
  arm_binary[$arm_name]=$spec_binary
  arm_env[$arm_name]=$spec_env
done

layer_kind_of() {
  case "${arm_image[$1]}" in
    store-layer:*) echo store-layer ;;
    deps-layer:*) echo deps-layer ;;
    modules-layer:*) echo modules-layer ;;
    onerun-layer:*) echo onerun-layer ;;
    linked-layer:*) echo linked-layer ;;
    *) echo none ;;
  esac
}
is_layered_arm() { [ "$(layer_kind_of "$1")" != none ]; }
has_image_project() {
  case "$(layer_kind_of "$1")" in deps-layer|modules-layer|onerun-layer) return 0 ;; *) return 1 ;; esac
}
is_dropped_on_failure() {
  case "$(layer_kind_of "$1")" in modules-layer|linked-layer) return 0 ;; *) return 1 ;; esac
}
layer_source_of() { echo "${arm_image[$1]#*:}"; }

for arm_name in "${arm_names[@]}"; do
  is_layered_arm "$arm_name" || continue
  layer_source=$(layer_source_of "$arm_name")
  if [ -z "${arm_image[$layer_source]:-}" ] || is_layered_arm "$layer_source"; then
    echo "arm $arm_name: '$layer_source' is not an unlayered arm of ARMS" >&2; exit 1
  fi
  # The layer image runs its install at build time with the image's pnpm.
  if [ "${arm_binary[$arm_name]}" != image ] || [ "${arm_binary[$layer_source]}" != image ]; then
    echo "arm $arm_name: a layered arm and its source must both use binary 'image'" >&2; exit 1
  fi
done

mkdir -p "$WORK" "$OUT/gate"
{
  grep -m1 'model name' /proc/cpuinfo
  echo "nproc: $(nproc)"
  echo "kernel: $(uname -r)"
  echo "fixture: $FIXTURE_REPO@$FIXTURE_SHA"
  # A hardlink to a lower-layer file copies the whole file up unless metacopy is on.
  echo "docker storage driver: $(docker info -f '{{.Driver}}')"
  echo "overlay metacopy: $(cat /sys/module/overlay/parameters/metacopy 2>/dev/null || echo unknown)"
  for arm_name in "${arm_names[@]}"; do
    echo "arm $arm_name image=${arm_image[$arm_name]} binary=${arm_binary[$arm_name]} env=${arm_env[$arm_name]:-none}"
  done
} | tee "$OUT/host.txt"

container_of() { echo "pip-$1"; }

cleanup_containers() {
  for arm_name in "${arm_names[@]}"; do
    container_name=$(container_of "$arm_name")
    if docker inspect "$container_name" >/dev/null 2>&1; then
      # The work tree is owned by the containers' uid 1001: remove it from inside.
      docker exec -u root "$container_name" sh -c 'rm -rf /w/fx /w/store /w/strace-* /w/paths-*'
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

container_image_of() {
  if is_layered_arm "$1"; then echo "pnpm-probe-$1:local"; else echo "${arm_image[$1]}"; fi
}
project_dir_of() {
  if has_image_project "$1"; then echo /app; else echo /w/fx; fi
}
store_dir_of() {
  if is_layered_arm "$1"; then echo /opt/store; else echo /w/store; fi
}

start_container() {
  local arm_name=$1 container_name network_args=()
  container_name=$(container_of "$arm_name")
  mkdir -p "$WORK/$container_name"
  if is_layered_arm "$arm_name"; then network_args=(--network none); fi
  docker run -d --name "$container_name" --entrypoint sleep "${network_args[@]}" \
    --cpus="$CPUS" --memory="$MEMORY" \
    --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    -e HOME=/home/runner \
    -v "$WORK/$container_name:/w" -v "$WORK/bins:/bins:ro" -v "$fixture_dir:/fixture:ro" \
    "$(container_image_of "$arm_name")" infinity >/dev/null
}

# The store sits on the same mount as node_modules, so pnpm hardlinks from it.
# A layered image has strace baked in and runs without network.
prepare_work_tree() {
  local arm_name=$1 install_strace=true
  if is_layered_arm "$arm_name"; then install_strace=false; fi
  docker exec -u root -e INSTALL_STRACE="$install_strace" "$(container_of "$arm_name")" sh -c '
    set -e
    rm -rf /w/fx /w/store && cp -r /fixture /w/fx && mkdir -p /w/store && chown -R 1001:1001 /w
    [ "$INSTALL_STRACE" = true ] || exit 0
    if command -v apk >/dev/null; then apk add -q strace >/dev/null
    else apt-get -qq update && apt-get -qq install -y strace >/dev/null; fi'
}
for arm_name in "${arm_names[@]}"; do
  is_layered_arm "$arm_name" && continue
  start_container "$arm_name"
  prepare_work_tree "$arm_name"
done

# Which pnpm each arm runs, read the way the install resolves it. A layered
# arm runs its source arm's image, so its source's line names its pnpm.
for arm_name in "${arm_names[@]}"; do
  is_layered_arm "$arm_name" && continue
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
  is_layered_arm "$arm_name" && continue
  docker cp -q "$OUT/pnpm-lock.yaml" "$(container_of "$arm_name"):/w/fx/pnpm-lock.yaml"
  docker exec -u root "$(container_of "$arm_name")" chown 1001:1001 /w/fx/pnpm-lock.yaml
done
echo "lockfile sha256=$(sha256sum "$OUT/pnpm-lock.yaml" | cut -c1-16)" | tee -a "$OUT/host.txt"

remove_node_modules() {
  docker exec -u 1001 -w /w/fx "$(container_of "$1")" sh -c 'find . -name node_modules -type d -prune -exec rm -rf {} +'
}

# Puts an arm back in the state its next counted install starts from: no
# node_modules on /w, and for a layered arm a fresh container, so the image's
# overlay is untouched (an arm with its project in the image keeps the
# node_modules of its image).
reset_arm() {
  local arm_name=$1
  if ! has_image_project "$arm_name"; then remove_node_modules "$arm_name"; fi
  if is_layered_arm "$arm_name"; then
    docker rm -f "$(container_of "$arm_name")" >/dev/null
    start_container "$arm_name"
  fi
  if [ "$(layer_kind_of "$arm_name")" = linked-layer ]; then link_image_modules "$arm_name" >/dev/null; fi
}

# Points every node_modules of the /w checkout at its twin under /app, as a
# consumer whose checkout lives outside the deps image would.
link_image_modules() {
  docker exec -u 1001 "$(container_of "$1")" sh -c '
    set -e
    cd /w/fx
    find . -name node_modules -type d -prune -exec rm -rf {} +
    cd /app
    find . -name node_modules -type d -prune | while read -r modules_dir; do
      ln -s "/app/${modules_dir#./}" "/w/fx/${modules_dir#./}"
    done
    find /w/fx -name node_modules -type l | wc -l'
}

install_env_args() {
  if [ -n "${arm_env[$1]}" ]; then echo "-e ${arm_env[$1]}"; fi
}

run_install() {
  local arm_name=$1 log_file=$2 env_args
  shift 2
  read -r -a env_args <<<"$(install_env_args "$arm_name")"
  docker exec -u 1001 "${env_args[@]}" -w "$(project_dir_of "$arm_name")" "$(container_of "$arm_name")" \
    "$@" "$(pnpm_command "$arm_name")" install \
    --frozen-lockfile --offline --store-dir="$(store_dir_of "$arm_name")" >"$log_file" 2>&1
}

# Warm every arm online once: fills its store, and proves its pnpm installs the
# shared lockfile before any count is taken.
for arm_name in "${arm_names[@]}"; do
  is_layered_arm "$arm_name" && continue
  container_name=$(container_of "$arm_name")
  remove_node_modules "$arm_name"
  docker exec -u 1001 -w /w/fx "$container_name" "$(pnpm_command "$arm_name")" install \
    --frozen-lockfile --store-dir=/w/store >"$OUT/warm-$arm_name.log" 2>&1 \
    || { echo "warm install failed for $arm_name" >&2; tail -30 "$OUT/warm-$arm_name.log"; exit 1; }
  file_count=$(docker exec "$container_name" sh -c 'find /w/fx -path "*/node_modules/*" -type f | wc -l')
  echo "warm $arm_name node_modules_files=$file_count" | tee -a "$OUT/host.txt"
  docker network disconnect bridge "$container_name"
done

# A layered arm's image: its source arm's image plus the store and the metadata
# cache that arm's warm install filled (an offline install reads the cache for
# its lockfile policy check), and for deps-layer the project installed at /app.
# modules-layer installs /app from the store mounted for that one RUN only.
build_layer_image() {
  local arm_name=$1 layer_kind layer_source context_dir
  layer_kind=$(layer_kind_of "$arm_name")
  layer_source=$(layer_source_of "$arm_name")
  context_dir=$WORK/layer-$arm_name
  mkdir -p "$context_dir"
  cp "$OUT/pnpm-lock.yaml" "$context_dir/pnpm-lock.yaml"
  rm -rf "$WORK/cache-$layer_source"
  docker cp -q "$(container_of "$layer_source"):/home/runner/.cache/pnpm" "$WORK/cache-$layer_source"
  {
    echo "FROM ${arm_image[$layer_source]}"
    echo 'USER root'
    echo 'RUN if command -v apk >/dev/null; then apk add -q strace; else apt-get -qq update && apt-get -qq install -y strace; fi'
    echo 'COPY --from=metadata --chown=1001:1001 . /home/runner/.cache/pnpm'
    if [ "$layer_kind" = modules-layer ]; then
      echo 'RUN mkdir -p /opt/store && chown 1001:1001 /opt/store'
      echo 'COPY --from=fixture --chown=1001:1001 . /app'
      echo 'COPY --chown=1001:1001 pnpm-lock.yaml /app/pnpm-lock.yaml'
      echo 'USER 1001'
      echo 'ENV HOME=/home/runner'
      # A bind mount of a local context is root-owned, so the store is copied
      # in as 1001 and emptied in the same RUN: node_modules keeps its
      # hardlinked inodes, the layer keeps no store path.
      echo 'RUN --mount=type=bind,from=store,target=/mnt/store cp -R /mnt/store/. /opt/store && cd /app && pnpm install --frozen-lockfile --offline --store-dir=/opt/store && find /opt/store -mindepth 1 -delete'
    elif [ "$layer_kind" = onerun-layer ] || [ "$layer_kind" = linked-layer ]; then
      echo 'RUN mkdir -p /opt/store && chown 1001:1001 /opt/store'
      echo 'COPY --from=fixture --chown=1001:1001 . /app'
      echo 'COPY --chown=1001:1001 pnpm-lock.yaml /app/pnpm-lock.yaml'
      echo 'USER 1001'
      echo 'ENV HOME=/home/runner'
      # The seed stands in for the previous deps image's store; prune drops
      # whatever this lockfile does not use, in the same RUN as the links.
      echo 'RUN --mount=type=bind,from=store,target=/mnt/seed cp -R /mnt/seed/. /opt/store && cd /app && pnpm install --frozen-lockfile --offline --store-dir=/opt/store && pnpm store prune --store-dir=/opt/store'
    else
      echo 'COPY --from=store --chown=1001:1001 . /opt/store'
    fi
    if [ "$layer_kind" = deps-layer ]; then
      echo 'COPY --from=fixture --chown=1001:1001 . /app'
      echo 'COPY --chown=1001:1001 pnpm-lock.yaml /app/pnpm-lock.yaml'
      echo 'USER 1001'
      echo 'ENV HOME=/home/runner'
      echo 'RUN cd /app && pnpm install --frozen-lockfile --offline --store-dir=/opt/store'
    fi
  } >"$context_dir/Dockerfile"
  docker build --progress=plain -t "$(container_image_of "$arm_name")" \
    --build-context store="$WORK/$(container_of "$layer_source")/store" \
    --build-context metadata="$WORK/cache-$layer_source" \
    --build-context fixture="$fixture_dir" "$context_dir" >"$OUT/layer-build-$arm_name.log" 2>&1 \
    || { echo "layer image build failed for $arm_name" >&2; tail -30 "$OUT/layer-build-$arm_name.log" >&2; exit 1; }
}

dropped_arms=()
for arm_name in "${arm_names[@]}"; do
  is_layered_arm "$arm_name" || continue
  build_layer_image "$arm_name"
  layer_source=$(layer_source_of "$arm_name")
  image_bytes=$(docker image inspect -f '{{.Size}}' "$(container_image_of "$arm_name")")
  base_bytes=$(docker image inspect -f '{{.Size}}' "${arm_image[$layer_source]}")
  echo "layer $arm_name kind=$(layer_kind_of "$arm_name") source=$layer_source image_bytes=$image_bytes base_bytes=$base_bytes" \
    | tee -a "$OUT/host.txt"
  start_container "$arm_name"
  prepare_work_tree "$arm_name"
  container_name=$(container_of "$arm_name")
  docker cp -q "$OUT/pnpm-lock.yaml" "$container_name:/w/fx/pnpm-lock.yaml"
  docker exec -u root "$container_name" chown 1001:1001 /w/fx/pnpm-lock.yaml
  if [ "$(layer_kind_of "$arm_name")" = linked-layer ]; then
    echo "linked $arm_name node_modules_links=$(link_image_modules "$arm_name")" | tee -a "$OUT/host.txt"
  fi
  # One uncounted offline install proves the layout installs before any count;
  # a linked checkout must also resolve a dependency through its links.
  warm_failure=""
  if ! run_install "$arm_name" "$OUT/warm-$arm_name.log"; then
    tail -30 "$OUT/warm-$arm_name.log"
    warm_failure="offline install fails, see warm-$arm_name.log"
  elif [ "$(layer_kind_of "$arm_name")" = linked-layer ]; then
    link_count=$(docker exec "$container_name" sh -c 'find /w/fx -name node_modules -type l | wc -l')
    echo "linked $arm_name node_modules_links_after_install=$link_count" | tee -a "$OUT/host.txt"
    if ! docker exec -u 1001 -w /w/fx/packages/vitest "$container_name" \
      node -e "console.log(require.resolve('tinyrainbow'))" >"$OUT/resolve-$arm_name.log" 2>&1; then
      cat "$OUT/resolve-$arm_name.log"
      warm_failure="require through the links fails, see resolve-$arm_name.log"
    fi
    # A workspace package resolves through the image's link, so to /app's copy
    # of the sources, not to the checkout under test.
    workspace_target=$(docker exec -u 1001 -w /w/fx/packages/vitest "$container_name" \
      node -e "console.log(require.resolve('@vitest/expect/package.json'))" 2>&1) \
      || workspace_target="resolve failed: $workspace_target"
    echo "linked $arm_name workspace_package_resolves_to=$workspace_target" | tee -a "$OUT/host.txt"
  fi
  if [ -n "$warm_failure" ]; then
    is_dropped_on_failure "$arm_name" || { echo "warm install failed for $arm_name: $warm_failure" >&2; exit 1; }
    # Whether this layout installs at all is what this arm asks.
    echo "::warning::$arm_name dropped: $warm_failure"
    echo "dropped $arm_name: $warm_failure" | tee -a "$OUT/host.txt"
    docker rm -f "$container_name" >/dev/null
    dropped_arms+=("$arm_name")
    continue
  fi
  file_count=$(docker exec "$container_name" sh -c \
    "find $(project_dir_of "$arm_name") -path '*/node_modules/*' -type f | wc -l")
  echo "warm $arm_name node_modules_files=$file_count" | tee -a "$OUT/host.txt"
done

if [ "${#dropped_arms[@]}" -gt 0 ]; then
  kept_arms=()
  for arm_name in "${arm_names[@]}"; do
    [[ " ${dropped_arms[*]} " == *" $arm_name "* ]] || kept_arms+=("$arm_name")
  done
  arm_names=("${kept_arms[@]}")
fi

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
    reset_arm "$arm_name"
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

for strace_round in $(seq 1 "$STRACE_ROUNDS"); do
  for offset in $(seq 0 $((arm_count - 1))); do
    arm_name=${arm_names[$(((strace_round + offset) % arm_count))]}
    container_name=$(container_of "$arm_name")
    strace_name=strace-$arm_name-r$strace_round
    reset_arm "$arm_name"
    run_install "$arm_name" "$OUT/$strace_name.log" strace -f -c -o "/w/$strace_name.txt" \
      || { echo "strace install failed: $arm_name round $strace_round" >&2; tail -30 "$OUT/$strace_name.log" >&2; exit 1; }
    docker cp -q "$container_name:/w/$strace_name.txt" "$OUT/$strace_name.txt"
  done
done

# Which paths each stat-family call names, to see what a version stats twice.
for arm_name in $STRACE_PATH_ARMS; do
  [ -n "${arm_image[$arm_name]:-}" ] || { echo "STRACE_PATH_ARMS names unknown arm $arm_name" >&2; exit 1; }
  reset_arm "$arm_name"
  container_name=$(container_of "$arm_name")
  run_install "$arm_name" "$OUT/paths-install-$arm_name.log" \
    strace -f -qq -e trace=%stat,%lstat,%fstat -o "/w/paths-$arm_name.txt" \
    || { echo "path trace failed: $arm_name" >&2; tail -30 "$OUT/paths-install-$arm_name.log" >&2; exit 1; }
  docker cp -q "$container_name:/w/paths-$arm_name.txt" "$OUT/paths-$arm_name.txt"
  python3 "$(dirname "$0")/pnpm-stat-paths.py" "$OUT/paths-$arm_name.txt" >"$OUT/paths-$arm_name.summary.txt"
  gzip -9 "$OUT/paths-$arm_name.txt"
done

if [ -n "$PERF_CMD" ]; then
  perf_events=task-clock,page-faults,minor-faults,major-faults,context-switches,cpu-migrations
  for arm_name in "${arm_names[@]}"; do
    reset_arm "$arm_name"
    container_name=$(container_of "$arm_name")
    container_pid=$(docker inspect -f '{{.State.Pid}}' "$container_name")
    cgroup_path=$(sed -n 's/^0:://p' "/proc/$container_pid/cgroup")
    # perf wants every -e before -G, and one -G entry per event.
    cgroup_list=$(printf "${cgroup_path#/},%.0s" 1 2 3 4 5 6)
    read -r -a env_args <<<"$(install_env_args "$arm_name")"
    $PERF_CMD stat -a -e "$perf_events" -G "${cgroup_list%,}" -o "$OUT/perf-$arm_name.txt" -- \
      docker exec -u 1001 "${env_args[@]}" -w "$(project_dir_of "$arm_name")" "$container_name" \
      "$(pnpm_command "$arm_name")" install \
      --frozen-lockfile --offline --store-dir="$(store_dir_of "$arm_name")" >"$OUT/perf-install-$arm_name.log" 2>&1 \
      || { echo "perf stat failed for $arm_name" >&2; tail -30 "$OUT/perf-install-$arm_name.log" >&2; exit 1; }
  done
fi
# The store and metadata cache an actions/cache consumer would restore, kept
# past the EXIT cleanup so the workflow can save them for the restore timing.
if [ -n "$STORE_EXPORT_ARM" ]; then
  [ -n "${arm_image[$STORE_EXPORT_ARM]:-}" ] && ! is_layered_arm "$STORE_EXPORT_ARM" \
    || { echo "STORE_EXPORT_ARM $(printf %q "$STORE_EXPORT_ARM") is not an unlayered arm" >&2; exit 1; }
  rm -rf "$WORK/export" && mkdir -p "$WORK/export"
  cp -a "$WORK/$(container_of "$STORE_EXPORT_ARM")/store" "$WORK/export/store"
  docker cp -q "$(container_of "$STORE_EXPORT_ARM"):/home/runner/.cache/pnpm" "$WORK/export/metadata"
  echo "export $STORE_EXPORT_ARM bytes=$(du -sb "$WORK/export" | cut -f1)" | tee -a "$OUT/host.txt"
fi
echo "=== DONE ===" | tee -a "$OUT/runs.txt"
