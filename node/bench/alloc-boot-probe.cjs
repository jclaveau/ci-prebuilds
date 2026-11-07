#!/usr/bin/env node
/*
 * Splits node-perf-gate's alloc_buffers and boot_e0 rows into their parts, so
 * an arm's gap can be pinned on one of them (node-alloc-boot-profile.yml).
 *
 *   alloc_zero      the gate's row: Buffer.alloc(64-72 KiB), zero-filled
 *   alloc_unsafe    same sizes, Buffer.allocUnsafeSlow: no zero-fill
 *   array_buffer    same sizes, new ArrayBuffer: V8's own zero-filled path
 *   boot_version    `node --version`: exec, dynamic link, static init, no V8
 *   boot_e0         the gate's row: `node -e 0`
 *   boot_e0_nopre   `node -e 0` with LD_PRELOAD emptied: the preload's share
 *
 * CPU-ms off the container's cgroup, median over the reps, as the kernel.
 *
 *   node alloc-boot-probe.cjs time               one json line of medians
 *   node alloc-boot-probe.cjs loop <row> <secs>  repeat a row, for perf/strace
 *   node alloc-boot-probe.cjs once <row>         one run of a row
 */
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');

function readCgroupUsec() {
  const stat = fs.readFileSync('/sys/fs/cgroup/cpu.stat', 'utf8');
  const usageLine = stat.split('\n').find(line => line.startsWith('usage_usec '));
  if (!usageLine) {
    throw new Error('alloc-boot-probe: /sys/fs/cgroup/cpu.stat has no usage_usec (cgroup v1?)');
  }
  return Number(usageLine.split(' ')[1]);
}

function medianOf(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function spawnChecked(args, extraEnv) {
  const result = spawnSync(process.execPath, args, {
    stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, ...extraEnv },
  });
  if (result.status !== 0) {
    throw new Error(`alloc-boot-probe: node ${JSON.stringify(args)} exited ${JSON.stringify(result.status)}: ${JSON.stringify(String(result.stderr))}`);
  }
}

let sinkValue = 0;

function allocLoop(allocateBuffer) {
  for (let index = 0; index < 20000; index++) {
    const buffer = allocateBuffer(65536 + (index % 64) * 128);
    sinkValue ^= buffer.byteLength;
  }
}

const ROWS = {
  alloc_zero: { reps: 5, run() { allocLoop(size => Buffer.alloc(size)); } },
  alloc_unsafe: { reps: 5, run() { allocLoop(size => Buffer.allocUnsafeSlow(size)); } },
  array_buffer: { reps: 5, run() { allocLoop(size => new ArrayBuffer(size)); } },
  boot_version: { reps: 20, run() { spawnChecked(['--version']); } },
  boot_e0: { reps: 20, run() { spawnChecked(['-e', '0']); } },
  boot_e0_nopre: { reps: 20, run() { spawnChecked(['-e', '0'], { LD_PRELOAD: '' }); } },
};

function rowNamed(rowName) {
  if (!Object.hasOwn(ROWS, rowName)) {
    throw new Error(`alloc-boot-probe: no row ${JSON.stringify(rowName)}, rows are ${JSON.stringify(Object.keys(ROWS))}`);
  }
  return ROWS[rowName];
}

function timeRows() {
  const medians = {};
  for (const [rowName, row] of Object.entries(ROWS)) {
    row.run();
    const repCosts = [];
    for (let rep = 0; rep < row.reps; rep++) {
      const before = readCgroupUsec();
      row.run();
      repCosts.push((readCgroupUsec() - before) / 1000);
    }
    medians[rowName] = Number(medianOf(repCosts).toFixed(3));
  }
  console.log(JSON.stringify({ node: process.version, ld_preload: process.env.LD_PRELOAD || '', medians, sink: sinkValue }));
}

const [probeMode, rowName, secondsText] = process.argv.slice(2);
if (probeMode === 'time') {
  timeRows();
} else if (probeMode === 'loop') {
  const row = rowNamed(rowName);
  const deadline = Date.now() + Number(secondsText) * 1000;
  let runCount = 0;
  while (Date.now() < deadline) {
    row.run();
    runCount++;
  }
  console.log(`${rowName} ran ${runCount} times`);
} else if (probeMode === 'once') {
  rowNamed(rowName).run();
} else {
  throw new Error(`alloc-boot-probe: mode ${JSON.stringify(probeMode)} is not time, loop or once`);
}
