#!/bin/sh
# PGO training for the instrumented node in /usr/local: node-perf-gate's own
# rows, then npm, tsc, vite and vitest on a small fixture, the JS a CI job
# runs. Not pnpm: pnpm 12 (the pnpm image's 12.16.1) installs a static-pie
# executable, so `pnpm install` never runs this node, only the scripts it spawns.
#
# Every node process merges into a pool of 8 files (%8m) instead of writing one
# profile per pid: the spawn rows start hundreds of nodes.
set -eu

export LLVM_PROFILE_FILE=/pgo/raw/node-%8m.profraw
mkdir -p /pgo/raw /tmp/train-out
node -p 'process.version'

for run in 1 2; do
  node /train/node-perf-kernel.cjs --target train --run "$run" --out /tmp/train-out
done

cd /train/fixture
npm install --no-audit --no-fund
npx tsc --noEmit -p .
npx vite build
npx vitest run
rm -rf node_modules dist
npm ci --offline --no-audit --no-fund
npx vite build

llvm_bin=/usr/lib/llvm23/bin
"$llvm_bin/llvm-profdata" merge -o /tmp/node.profdata /pgo/raw/*.profraw
rm -rf /pgo/raw
"$llvm_bin/llvm-profdata" show /tmp/node.profdata | tee /tmp/profile-summary.txt
function_count=$(awk -F': ' '/^Total functions/ { print $2 }' /tmp/profile-summary.txt)
# A profile that covers a few hundred functions is a training run that crashed
# early or wrote to the wrong place, not a profile of node.
if [ -z "$function_count" ] || [ "$function_count" -lt 20000 ]; then
  echo "profile covers ${function_count:-no} functions: training did not exercise node" >&2
  exit 1
fi
profile_sha=$(sha256sum /tmp/node.profdata | cut -c1-16)
mv /tmp/node.profdata "/pgo/node-${profile_sha}.profdata"
ls -l /pgo
