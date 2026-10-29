#!/usr/bin/env node
/*
 * node-perf-gate's kernel (#351): one shot of every row, written as the probe
 * json playwright/bench/assert-perf-gate.py reads.
 *
 * Every row is timed in CPU-ms off the container's cgroup (cpu.stat
 * usage_usec), not the wall clock and not process.cpuUsage(): the spawn rows'
 * cost lives in the children, and the cgroup is the one counter that sees them
 * on every image whatever the libc. A row's value is the median over its reps.
 *
 *   cpu_loop          control: pure JIT'd integer work, must read ~1.00
 *   boot_e0           `node -e 0`: code cache, dynamic linking, preload tax
 *   require_builtins  fresh node requiring every builtin: code cache
 *   require_tree      fresh node requiring npm's CLI + arborist: resolution + fs
 *   spawn_true_x100   100 spawns of PATH's `true`: the spawn path + what it execs
 *   fs_walk           lstat every entry of a generated 1800-file tree, 4 passes
 *   alloc_buffers     ~70 KB Buffer.alloc churn: musl mallocng mmap/munmap
 *   alloc_objs        short-lived small objects: V8 young gen
 *   json_roundtrip    stringify + parse a ~4 MB document
 *   gzip_20MB         zlib deflate + inflate: bundled vs system zlib
 *   sha256_100MB      crypto hash: bundled vs system openssl
 *   http_rtt_x2000    keep-alive loopback requests: libuv + llhttp
 *
 * SIZING RULE (as runtime-probe.cjs): a rep should cost well over 1 ms of CPU
 * so cgroup accounting and scheduler noise stay under ~1% of it.
 *
 * No network, no fixture download: npm ships inside every node install, so
 * require_tree reads the image's own copy. fs_walk does not: two installs of
 * the same node version ship different npm trees (24.22.1: 1926 files in the
 * musl tarball vs 1614 in ubuntu's), so it walks a tree generated in the
 * temp directory, identical on every arm.
 *
 * Usage: node node-perf-kernel.cjs --target <arm> --run <n> --out <dir>
 */
const { spawnSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');

function readArgument(name) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1 || !process.argv[index + 1]) {
    throw new Error(`node-perf-kernel: missing --${name}`);
  }
  return process.argv[index + 1];
}

const targetName = readArgument('target');
const runNumber = readArgument('run');
const outDirectory = readArgument('out');

function readCgroupUsec() {
  const stat = fs.readFileSync('/sys/fs/cgroup/cpu.stat', 'utf8');
  const usageLine = stat.split('\n').find(line => line.startsWith('usage_usec '));
  if (!usageLine) {
    throw new Error('node-perf-kernel: /sys/fs/cgroup/cpu.stat has no usage_usec (cgroup v1?)');
  }
  return Number(usageLine.split(' ')[1]);
}

function medianOf(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

const npmDirectory = path.join(path.dirname(process.execPath), '..', 'lib', 'node_modules', 'npm');
if (!fs.existsSync(path.join(npmDirectory, 'package.json'))) {
  throw new Error(`node-perf-kernel: no npm at ${npmDirectory}`);
}

function spawnChecked(command, args) {
  const result = spawnSync(command, args, { stdio: ['ignore', 'ignore', 'pipe'] });
  if (result.status !== 0) {
    throw new Error(`node-perf-kernel: ${command} ${args.join(' ')} exited ${result.status}: ${result.stderr}`);
  }
}

function walkTree(directory) {
  let fileCount = 0;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    fs.lstatSync(entryPath);
    fileCount += entry.isDirectory() ? walkTree(entryPath) : 1;
  }
  return fileCount;
}

// Built once, outside any timed region: the inputs every rep reuses.
// 15 x 30 directories of 4 files each, about npm's shape (450 dirs, 1800 files).
const walkRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'node-perf-walk-'));
for (let topIndex = 0; topIndex < 15; topIndex++) {
  for (let subIndex = 0; subIndex < 30; subIndex++) {
    const directory = path.join(walkRoot, `d${topIndex}`, `d${subIndex}`);
    fs.mkdirSync(directory, { recursive: true });
    for (let fileIndex = 0; fileIndex < 4; fileIndex++) {
      fs.writeFileSync(path.join(directory, `f${fileIndex}.js`), '');
    }
  }
}
const jsonDocument = Array.from({ length: 40000 }, (_, index) => ({
  id: index, name: `item-${index}`, tags: ['a', 'b', 'c'], score: index * 0.5, nested: { ok: true },
}));
const gzipInput = Buffer.alloc(20 * 1024 * 1024);
for (let offset = 0; offset < gzipInput.length; offset += 4) {
  gzipInput.writeUInt32LE((offset * 2654435761) % 1000, offset);
}
const hashInput = Buffer.alloc(100 * 1024 * 1024, 7);

let sinkValue = 0;

const ROWS = {
  cpu_loop: { reps: 5, run() {
    let accumulator = 0;
    for (let index = 0; index < 150e6; index++) accumulator = (accumulator + index * 7) | 0;
    sinkValue ^= accumulator;
  } },
  boot_e0: { reps: 20, run() { spawnChecked(process.execPath, ['-e', '0']); } },
  require_builtins: { reps: 10, run() {
    spawnChecked(process.execPath, ['-e',
      "for (const m of require('module').builtinModules) { try { require(m) } catch {} }"]);
  } },
  require_tree: { reps: 10, run() {
    // npm's main throws (no programmatic API since v8); its CLI and arborist
    // modules are what `npm install` loads, ~540 files.
    const entryPaths = ['lib/npm.js', 'lib/commands/install.js', 'node_modules/@npmcli/arborist']
      .map(entry => JSON.stringify(path.join(npmDirectory, entry)));
    spawnChecked(process.execPath, ['-e', entryPaths.map(entry => `require(${entry})`).join(';')]);
  } },
  spawn_true_x100: { reps: 5, run() {
    for (let index = 0; index < 100; index++) spawnChecked('true', []);
  } },
  fs_walk: { reps: 5, run() {
    for (let pass = 0; pass < 4; pass++) sinkValue ^= walkTree(walkRoot);
  } },
  alloc_buffers: { reps: 5, run() {
    for (let index = 0; index < 20000; index++) {
      const buffer = Buffer.alloc(65536 + (index % 64) * 128);
      sinkValue ^= buffer[0];
    }
  } },
  alloc_objs: { reps: 5, run() {
    let kept = null;
    for (let index = 0; index < 15e6; index++) kept = { index, next: kept && kept.index };
    sinkValue ^= kept.index;
  } },
  json_roundtrip: { reps: 5, run() {
    sinkValue ^= JSON.parse(JSON.stringify(jsonDocument)).length;
  } },
  gzip_20MB: { reps: 5, run() {
    sinkValue ^= zlib.gunzipSync(zlib.gzipSync(gzipInput)).length;
  } },
  sha256_100MB: { reps: 5, run() {
    sinkValue ^= crypto.createHash('sha256').update(hashInput).digest()[0];
  } },
  http_rtt_x2000: { reps: 5, async run() {
    const server = http.createServer((request, response) => response.end('ok'));
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
    const { port } = server.address();
    for (let index = 0; index < 2000; index++) {
      await new Promise((resolve, reject) => {
        http.get({ host: '127.0.0.1', port, agent }, response => {
          response.resume();
          response.on('end', resolve);
        }).on('error', reject);
      });
    }
    agent.destroy();
    await new Promise(resolve => server.close(resolve));
  } },
};

async function main() {
  const metrics = {};
  for (const [rowName, row] of Object.entries(ROWS)) {
    // One untimed rep first: JIT, page cache and the dynamic loader's caches
    // are warm for every arm alike before anything is counted.
    await row.run();
    const repCosts = [];
    for (let rep = 0; rep < row.reps; rep++) {
      const before = readCgroupUsec();
      await row.run();
      repCosts.push((readCgroupUsec() - before) / 1000);
    }
    metrics[rowName] = { median_ms: Number(medianOf(repCosts).toFixed(3)), reps_ms: repCosts };
    console.log(`${targetName} run${runNumber} ${rowName} ${metrics[rowName].median_ms} ms`);
  }
  const document = {
    target: targetName,
    node: process.version,
    ld_preload: process.env.LD_PRELOAD || '',
    code_cache: process.config.variables.node_use_node_code_cache,
    sink: sinkValue,
    metrics,
  };
  fs.writeFileSync(path.join(outDirectory, `${targetName}-node-run${runNumber}.json`),
    JSON.stringify(document, null, 2));
  fs.rmSync(walkRoot, { recursive: true });
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
