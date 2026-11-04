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
# Alpine's clang predefines _FORTIFY_SOURCE=2, and fortify-headers' inline
# memcpy guards every fixed-size copy with a two-range overlap compare and a
# ud2 clang cannot fold; in zlib's insert_string loop that cost gzip_20MB
# 1.07-1.25x on Zen 4/5. The overlap trap goes, the size trap stays: the same
# check glibc's __memcpy_chk makes.
python3 - <<'PY'
import pathlib
header = pathlib.Path('/usr/include/fortify/string.h')
header_text = header.read_text()
overlap_trap = """	if ((__d < __s && __d + __n > __s) ||
	    (__s < __d && __s + __n > __d))
		__builtin_trap();
	if (__n > __bd || __n > __bs)"""
trap_count = header_text.count(overlap_trap)
# A resumed round starts from the previous round's layer, header already edited.
if trap_count == 0 and '__d + __n > __s' not in header_text:
    print('fortify-headers memcpy overlap trap already removed (resumed round)')
elif trap_count == 1:
    header.write_text(header_text.replace(overlap_trap, "	if (__n > __bd || __n > __bs)"))
else:
    raise SystemExit(f'fortify-headers memcpy overlap trap found {trap_count} times, expected 1')
PY
export CFLAGS="$thin_lto_flags $profile_flags"
export CXXFLAGS="$thin_lto_flags $profile_flags"
export LDFLAGS="$link_flags"

# A cold compile takes ~5.8 h on a 4-vCPU runner (run 40955771149), past what
# the job has left once the toolchain is up. make stops at MAKE_BUDGET. With
# MAKE_RESUMABLE set (CI), the run then ends cleanly with "unfinished" in
# /work/make-status, CI pushes this layer, out/ included, as a resume image,
# and the next round builds from it, so make only compiles what is missing.
# Without it, the run fails and its rerun compiles from sccache.
make_budget=${MAKE_BUDGET:-310m}
make_status_file=/work/make-status

# A budget overrun leaves compilers running after make dies, and an object
# written as the container stops would be truncated yet newer than its source.
# Stop the whole process group, then drop every object written near the stop.
stop_make_group() {
  local make_group=$1
  local recent_marker=/tmp/make-stopped-marker
  python3 -c 'import os, sys, time
stamp = time.time() - 300
open(sys.argv[1], "w").close()
os.utime(sys.argv[1], (stamp, stamp))' "$recent_marker"
  kill -TERM -- "-$make_group" 2>/dev/null || echo "make's process group had already exited"
  local waited_seconds=0
  while kill -0 -- "-$make_group" 2>/dev/null; do
    if [ "$waited_seconds" -ge 120 ]; then
      echo "make's process group was still running 120 s after SIGTERM" >&2
      exit 1
    fi
    sleep 1
    waited_seconds=$((waited_seconds + 1))
  done
  sccache --stop-server || echo "the sccache server was already gone (it ran in make's group)"
  local dropped_count
  dropped_count=$(find out \( -name '*.o' -o -name '*.a' \) -type f -newer "$recent_marker" -print -delete | wc -l)
  echo "dropped $dropped_count objects written in the last 5 min before the stop, the next round rebuilds them"
}

# make's output is a log, not a progress bar: only the links reach the job log.
run_make() {
  local log_file=$1
  shift
  local make_status=0
  # setsid: make leads its own process group, so stop_make_group reaches the
  # compilers it leaves behind (busybox timeout signals make alone).
  timeout "$make_budget" setsid make -j"$(nproc)" "$@" >"$log_file" 2>&1 &
  local make_pid=$!
  wait "$make_pid" || make_status=$?
  # busybox timeout exits 143 (SIGTERM), coreutils' 124.
  if [ "$make_status" -eq 124 ] || [ "$make_status" -eq 143 ]; then
    sccache --show-stats
    if [ -n "${MAKE_RESUMABLE:-}" ]; then
      stop_make_group "$make_pid"
      echo unfinished >"$make_status_file"
      echo "make ran out of its ${make_budget} budget: this layer is the resume point, the next round continues from it" >&2
      exit 0
    fi
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
# A resumed round keeps the previous round's configure: rerunning it rewrites
# the generated makefiles and config headers, and make would recompile all.
if [ -f "$make_status_file" ] && [ -f out/Makefile ]; then
  echo "resuming: $(cat "$make_status_file") round found, configure skipped"
else
  ./configure --prefix=/usr/local
fi
run_make /tmp/build.log
sccache --show-stats

if [ "$phase" = use ]; then
  # How much of the profile matched the code it is applied to: a mismatch on
  # the hot functions silently degrades PGO to a plain -O3 build.
  awk '/profile data may be out of date/ { stale++ } /no profile data available/ { missing++ }
       END { printf "PGO: %d files with stale profile data, %d with none\n", stale, missing }' /tmp/build.log
fi

node_exe=out/Release/node
# Symbol tables go to a file first: under pipefail, `llvm-nm | grep -q` fails
# whenever grep matches early and llvm-nm dies of SIGPIPE.
"$llvm_bin/llvm-nm" "$node_exe" >/tmp/node-symbols.txt
if grep -qE " [Tt] mi_malloc$" /tmp/node-symbols.txt; then
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
  "$llvm_bin/llvm-nm" -D "$node_exe" >/tmp/node-dynamic-symbols.txt
  "$llvm_bin/llvm-nm" "$node_exe" >/tmp/node-symbols.txt
  if ! grep -q ' T malloc$' /tmp/node-dynamic-symbols.txt; then
    grep -E ' (malloc|free|mi_malloc)$' /tmp/node-dynamic-symbols.txt /tmp/node-symbols.txt >&2 \
      || echo "no malloc, free or mi_malloc symbol at all" >&2
    echo "$node_exe does not export malloc: mimalloc would not interpose musl's" >&2
    exit 1
  fi
  # The link keeps mi_malloc local (t), at the address of the exported malloc.
  malloc_address=$(awk '$2 == "T" && $3 == "malloc" { print $1 }' /tmp/node-symbols.txt)
  mimalloc_address=$(awk '$2 ~ /^[Tt]$/ && $3 == "mi_malloc" { print $1 }' /tmp/node-symbols.txt)
  if [ -z "$mimalloc_address" ] || [ "$malloc_address" != "$mimalloc_address" ]; then
    grep -E ' (malloc|mi_malloc)$' /tmp/node-symbols.txt >&2 || true
    echo "$node_exe: malloc is not mimalloc's mi_malloc after the mimalloc link" >&2
    exit 1
  fi
  python3 tools/install.py install --dest-dir "$destdir_mimalloc" --prefix /usr/local
  "$destdir_mimalloc/usr/local/bin/node" -p 'process.version'
fi

rm -rf /work/node-src/out /work/thinlto-cache /tmp/build-tools-profraw
echo done >"$make_status_file"
