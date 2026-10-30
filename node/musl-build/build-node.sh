#!/usr/bin/env bash
# Builds node from /work/node-src with clang23 + ThinLTO, one PGO phase per call.
#
#   build-node.sh generate <destdir>                     instrumented, for pgo-train.sh
#   build-node.sh use <plain-destdir> <mimalloc-destdir> profile-guided, two links
#
# ThinLTO, not configure's --enable-lto: with clang that option is full LTO,
# one single-threaded link of all of V8, which a 16 GB hosted runner cannot be
# counted on to hold. PGO goes in through CFLAGS/LDFLAGS too: configure refuses
# --enable-pgo-* unless the compiler is gcc.
set -euo pipefail

phase=$1
cd /work/node-src

secret_value() {
  if [ -s "/run/secrets/$1" ]; then cat "/run/secrets/$1"; fi
}
ACTIONS_RUNTIME_TOKEN=$(secret_value actions_runtime_token)
ACTIONS_RESULTS_URL=$(secret_value actions_results_url)
if [ -n "$ACTIONS_RUNTIME_TOKEN" ] && [ -n "$ACTIONS_RESULTS_URL" ]; then
  export ACTIONS_RUNTIME_TOKEN ACTIONS_RESULTS_URL
  # Without the v2 switch every write fails (run 40955771149: 5929 compiles,
  # 5929 write errors, nothing stored).
  export SCCACHE_GHA_ENABLED=true SCCACHE_GHA_VERSION=node-musl ACTIONS_CACHE_SERVICE_V2=1
else
  echo "WARN: GHA cache env not provided, sccache uses the local cache mount only" >&2
fi

llvm_bin=/usr/lib/llvm23/bin
export CC="sccache clang-23" CXX="sccache clang++-23" AR="$llvm_bin/llvm-ar"
export CC_host="$CC" CXX_host="$CXX" AR_host="$AR"
thin_lto_flags="-flto=thin"
link_flags="-fuse-ld=lld $thin_lto_flags -Wl,--thinlto-jobs=$(nproc) -Wl,--thinlto-cache-dir=/work/thinlto-cache"

case "$phase" in
  generate)
    destdir_plain=$2
    profile_flags="-fprofile-generate"
    link_flags="$link_flags $profile_flags"
    # The instrumented build tools (mksnapshot, torque) write profiles as they
    # run; keep them out of the tree and out of the training set.
    export LLVM_PROFILE_FILE=/tmp/build-tools-profraw/%m.profraw
    ;;
  use)
    destdir_plain=$2
    destdir_mimalloc=$3
    profiles=(/pgo/node-*.profdata)
    if [ "${#profiles[@]}" -ne 1 ] || [ ! -s "${profiles[0]}" ]; then
      echo "expected exactly one /pgo/node-<sha>.profdata, found: ${profiles[*]}" >&2
      exit 1
    fi
    # The path carries the profile's sha, so a new profile is a new compile
    # command and sccache cannot hand back an object built against the old one.
    profile_flags="-fprofile-use=${profiles[0]}"
    ;;
  *)
    echo "usage: build-node.sh generate <destdir> | use <plain-destdir> <mimalloc-destdir>" >&2
    exit 2
    ;;
esac
export CFLAGS="$thin_lto_flags $profile_flags" CXXFLAGS="$thin_lto_flags $profile_flags"
export LDFLAGS="$link_flags"

# A cold compile takes ~5.8 h on a 4-vCPU runner (run 40955771149), past what
# the job has left once the toolchain is up. make stops at MAKE_BUDGET with the
# sccache stats printed, so the run fails saying so and its rerun compiles
# from cache instead of being cancelled silently by the job timeout.
make_budget=${MAKE_BUDGET:-310m}

# make's output is a log, not a progress bar: only the links reach the job log.
run_make() {
  local log_file=$1
  shift
  local make_status=0
  timeout "$make_budget" make -j"$(nproc)" "$@" >"$log_file" 2>&1 || make_status=$?
  if [ "$make_status" -eq 124 ]; then
    sccache --show-stats
    echo "make ran out of its ${make_budget} budget: the objects compiled so far are in sccache, rerun the job" >&2
    exit 1
  fi
  if [ "$make_status" -ne 0 ]; then
    tail -150 "$log_file" >&2
    exit 1
  fi
  grep -E '^  LINK' "$log_file" || { echo "make ran and linked nothing: $log_file" >&2; exit 1; }
}

clang-23 --version | head -1
./configure --prefix=/usr/local
run_make /tmp/build.log
sccache --show-stats

if [ "$phase" = use ]; then
  # How much of the profile matched the code it is applied to: a mismatch on
  # the hot functions silently degrades PGO to a plain -O3 build.
  awk '/profile data may be out of date/ { stale++ } /no profile data available/ { missing++ }
       END { printf "PGO: %d files with stale profile data, %d with none\n", stale, missing }' /tmp/build.log
fi

node_exe=out/Release/node
if "$llvm_bin/llvm-nm" "$node_exe" | grep -q ' T mi_malloc$'; then
  echo "$node_exe links mimalloc but no mimalloc link was asked for" >&2
  exit 1
fi
# install.py, not `make install`: that target reruns `all`, which regenerates
# the inspector protocol sources and recompiles their dependents serially.
python3 tools/install.py install --dest-dir "$destdir_plain" --prefix /usr/local
"$destdir_plain/usr/local/bin/node" -p 'process.version + " code_cache=" + process.config.variables.node_use_node_code_cache'

if [ "$phase" = use ]; then
  # Same objects, relinked: gyp reads LDFLAGS when make runs, and the changed
  # link command relinks every executable (mksnapshot too, hence a new
  # snapshot). The executable's own malloc interposes musl's for every library
  # node loads, as LD_PRELOAD would, without reaching node's children.
  export LDFLAGS="$link_flags -Wl,--whole-archive /usr/lib/libmimalloc-insecure.a -Wl,--no-whole-archive"
  run_make /tmp/build-mimalloc.log
  "$llvm_bin/llvm-nm" -D "$node_exe" | grep -q ' T malloc$' \
    || { echo "$node_exe does not export malloc: mimalloc would not interpose musl's" >&2; exit 1; }
  "$llvm_bin/llvm-nm" "$node_exe" | grep -q ' T mi_malloc$' \
    || { echo "$node_exe has no mi_malloc after the mimalloc link" >&2; exit 1; }
  python3 tools/install.py install --dest-dir "$destdir_mimalloc" --prefix /usr/local
  "$destdir_mimalloc/usr/local/bin/node" -p 'process.version'
fi

rm -rf /work/node-src/out /work/thinlto-cache /tmp/build-tools-profraw
