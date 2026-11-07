#!/usr/bin/env node
/*
 * Splits node-perf-gate's alloc_buffers and boot_e0 rows into their parts, so
 * an arm's gap can be pinned on one of them (node-alloc-boot-profile.yml).
 *
 *   alloc_touch     the gate's row: Buffer.alloc(64-72 KiB), first byte read
 *   alloc_zero      same, never read: the pages are never touched
 *   alloc_unsafe    same sizes, Buffer.allocUnsafeSlow: no zero-fill
 *   array_buffer    same sizes, new ArrayBuffer: V8's own zero-filled path
 *   boot_version    `node --version`: exec, dynamic link, static init, no V8
 *   boot_e0         the gate's row: `node -e 0`
 *   boot_e0_nopre   `node -e 0` with LD_PRELOAD emptied: the preload's share
 *
 * CPU-ms off the container's cgroup, median over the reps, as the kernel, and
 * the cgroup's page faults per rep. Boot rows run first, so the alloc rows'
 * heap does not weigh on their spawns.
 * PROBE_BALLAST=1 first allocates the kernel's live inputs (json, 20 MB gzip,
 * 100 MB hash), which the gate's process holds while it runs these two rows.
 * PROBE_PRELUDE=1 then runs what the gate runs before alloc_buffers: boot_e0,
 * require_builtins, require_tree, spawn_true_x100 and fs_walk, at its reps.
 *
 *   node alloc-boot-probe.cjs time               one json line of medians
 *   node alloc-boot-probe.cjs loop <row> <secs>  repeat a row, for perf/strace
 *   node alloc-boot-probe.cjs once <row>         one run of a row
 */
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function readCgroupUsec() {
  const stat = fs.readFileSync('/sys/fs/cgroup/cpu.stat', 'utf8');
  const usageLine = stat.split('\n').find(line => line.startsWith('usage_usec '));
  if (!usageLine) {
    throw new Error('alloc-boot-probe: /sys/fs/cgroup/cpu.stat has no usage_usec (cgroup v1?)');
  }
  return Number(usageLine.split(' ')[1]);
}

function readCgroupFaults() {
  const stat = fs.readFileSync('/sys/fs/cgroup/memory.stat', 'utf8');
  const faultLine = stat.split('\n').find(line => line.startsWith('pgfault '));
  if (!faultLine) {
    throw new Error('alloc-boot-probe: /sys/fs/cgroup/memory.stat has no pgfault');
  }
  return Number(faultLine.split(' ')[1]);
}

function medianOf(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function spawnChecked(args, extraEnv, command = process.execPath) {
  const result = spawnSync(command, args, {
    stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, ...extraEnv },
  });
  if (result.status !== 0) {
    throw new Error(`alloc-boot-probe: ${JSON.stringify(command)} ${JSON.stringify(args)} exited ${JSON.stringify(result.status)}: ${JSON.stringify(String(result.stderr))}`);
  }
}

const ballastInputs = [];
if (process.env.PROBE_BALLAST === '1') {
  ballastInputs.push(Array.from({ length: 40000 }, (_, index) => ({
    id: index, name: `item-${index}`, tags: ['a', 'b', 'c'], score: index * 0.5, nested: { ok: true },
  })));
  const gzipInput = Buffer.alloc(20 * 1024 * 1024);
  for (let offset = 0; offset < gzipInput.length; offset += 4) {
    gzipInput.writeUInt32LE((offset * 2654435761) % 1000, offset);
  }
  ballastInputs.push(gzipInput, Buffer.alloc(100 * 1024 * 1024, 7));
} else if (process.env.PROBE_BALLAST !== undefined && process.env.PROBE_BALLAST !== '0') {
  throw new Error(`alloc-boot-probe: PROBE_BALLAST is ${JSON.stringify(process.env.PROBE_BALLAST)}, not 0 or 1`);
}

let sinkValue = 0;

function walkTree(directory) {
  let fileCount = 0;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    fs.lstatSync(entryPath);
    fileCount += entry.isDirectory() ? walkTree(entryPath) : 1;
  }
  return fileCount;
}

function runGatePrelude() {
  const walkRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'alloc-boot-walk-'));
  for (let topIndex = 0; topIndex < 15; topIndex++) {
    for (let subIndex = 0; subIndex < 30; subIndex++) {
      const directory = path.join(walkRoot, `d${topIndex}`, `d${subIndex}`);
      fs.mkdirSync(directory, { recursive: true });
      for (let fileIndex = 0; fileIndex < 4; fileIndex++) {
        fs.writeFileSync(path.join(directory, `f${fileIndex}.js`), '');
      }
    }
  }
  const npmDirectory = path.join(path.dirname(process.execPath), '..', 'lib', 'node_modules', 'npm');
  const requireTreeScript = ['lib/npm.js', 'lib/commands/install.js', 'node_modules/@npmcli/arborist']
    .map(entry => `require(${JSON.stringify(path.join(npmDirectory, entry))})`).join(';');
  // The gate's reps plus its one warm-up per row.
  for (let rep = 0; rep < 21; rep++) spawnChecked(['-e', '0']);
  for (let rep = 0; rep < 11; rep++) {
    spawnChecked(['-e', "for (const m of require('module').builtinModules) { try { require(m) } catch {} }"]);
  }
  for (let rep = 0; rep < 11; rep++) spawnChecked(['-e', requireTreeScript]);
  for (let rep = 0; rep < 600; rep++) spawnChecked([], {}, 'true');
  for (let rep = 0; rep < 6; rep++) {
    for (let pass = 0; pass < 4; pass++) sinkValue ^= walkTree(walkRoot);
  }
}

if (process.env.PROBE_PRELUDE === '1') {
  runGatePrelude();
} else if (process.env.PROBE_PRELUDE !== undefined && process.env.PROBE_PRELUDE !== '0') {
  throw new Error(`alloc-boot-probe: PROBE_PRELUDE is ${JSON.stringify(process.env.PROBE_PRELUDE)}, not 0 or 1`);
}

function allocLoop(allocateBuffer) {
  for (let index = 0; index < 20000; index++) {
    const buffer = allocateBuffer(65536 + (index % 64) * 128);
    sinkValue ^= buffer.byteLength;
  }
}

const ROWS = {
  boot_version: { reps: 20, run() { spawnChecked(['--version']); } },
  boot_e0: { reps: 20, run() { spawnChecked(['-e', '0']); } },
  boot_e0_nopre: { reps: 20, run() { spawnChecked(['-e', '0'], { LD_PRELOAD: '' }); } },
  alloc_touch: { reps: 5, run() {
    for (let index = 0; index < 20000; index++) {
      sinkValue ^= Buffer.alloc(65536 + (index % 64) * 128)[0];
    }
  } },
  alloc_zero: { reps: 5, run() { allocLoop(size => Buffer.alloc(size)); } },
  alloc_unsafe: { reps: 5, run() { allocLoop(size => Buffer.allocUnsafeSlow(size)); } },
  array_buffer: { reps: 5, run() { allocLoop(size => new ArrayBuffer(size)); } },
};

function rowNamed(rowName) {
  if (!Object.hasOwn(ROWS, rowName)) {
    throw new Error(`alloc-boot-probe: no row ${JSON.stringify(rowName)}, rows are ${JSON.stringify(Object.keys(ROWS))}`);
  }
  return ROWS[rowName];
}

function timeRows() {
  const medians = {};
  const faults = {};
  for (const [rowName, row] of Object.entries(ROWS)) {
    row.run();
    const repCosts = [];
    const repFaults = [];
    for (let rep = 0; rep < row.reps; rep++) {
      const faultsBefore = readCgroupFaults();
      const before = readCgroupUsec();
      row.run();
      repCosts.push((readCgroupUsec() - before) / 1000);
      repFaults.push(readCgroupFaults() - faultsBefore);
    }
    medians[rowName] = Number(medianOf(repCosts).toFixed(3));
    faults[rowName] = medianOf(repFaults);
  }
  console.log(JSON.stringify({
    node: process.version, ld_preload: process.env.LD_PRELOAD || '', ballast_count: ballastInputs.length,
    prelude: process.env.PROBE_PRELUDE === '1', medians, faults, sink: sinkValue,
  }));
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
