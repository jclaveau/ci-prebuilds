#!/usr/bin/env node
/*
 * Times what `browserType.launch()` pays before a page exists: execve plus the
 * dynamic loader mapping the binary's DT_NEEDED closure and binding it.
 *
 * chromium's `launch` row reads 1.40-1.45x official on every CPU model drawn so
 * far, and both arms scale identically across those models, so it is a constant
 * factor rather than anything microarchitectural. The standing explanation is
 * the closure — ours links system libraries official bundles statically, 43
 * DT_NEEDED against 28 — and musl compounds it by binding every symbol
 * reference in every object at load where glibc resolves only what is called.
 * This prices that without a 25-30h rebuild.
 *
 * `--version` is the whole point of the kernel: it loads the closure, prints a
 * string and exits, so nothing after startup is in the number.
 *
 * /bin/true runs in the SAME loop as the control. It pays the same fork+execve
 * and none of the closure, so subtracting its median leaves the binary's own
 * load cost. Without that subtraction the result describes the runner's
 * process-spawn cost as much as the browser's.
 *
 * usage: startup-time.cjs <label> <binary>
 */
const { spawnSync } = require('child_process');

const RUNS = 25;
// The first exec of a binary pays page-cache misses the rest do not, and it is
// not what a test run pays per worker.
const WARMUP = 3;

const [label, binary] = process.argv.slice(2);
if (!label || !binary) {
  console.error('usage: startup-time.cjs <label> <binary>');
  process.exit(2);
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function timeSpawn(command, args) {
  const started = process.hrtime.bigint();
  const result = spawnSync(command, args, { encoding: 'utf8' });
  const elapsed = Number(process.hrtime.bigint() - started) / 1e6;
  return { elapsed, result };
}

function sample(command, args) {
  for (let i = 0; i < WARMUP; i++) timeSpawn(command, args);
  const timings = [];
  let last;
  for (let i = 0; i < RUNS; i++) {
    const { elapsed, result } = timeSpawn(command, args);
    timings.push(elapsed);
    last = result;
  }
  return { median: median(timings), min: Math.min(...timings), last };
}

const control = sample('/bin/true', []);
const browser = sample(binary, ['--version']);

// A binary that failed to load exits in microseconds and would otherwise
// report as the fastest arm in the table.
const printed = `${browser.last.stdout || ''}${browser.last.stderr || ''}`.trim();
const witness = /\d+\.\d+\.\d+/.test(printed) ? printed.split('\n')[0] : null;

console.log(JSON.stringify({
  label,
  binary,
  runs: RUNS,
  control_ms: control.median,
  version_ms: browser.median,
  load_ms: browser.median - control.median,
  version_min_ms: browser.min,
  witness,
}, null, 2));

if (!witness) {
  console.error(`FAILED: ${binary} --version printed no version: ${printed}`);
  process.exit(1);
}
