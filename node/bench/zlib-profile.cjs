#!/usr/bin/env node
/*
 * node-zlib-profile's row: node-perf-kernel's gzip_20MB input, with deflate
 * and inflate timed apart so a gap can be put on one side of zlib.
 *
 *   node zlib-profile.cjs time <reps>     median CPU-ms of gzipSync and gunzipSync
 *   node zlib-profile.cjs loop <seconds>  deflate + inflate until the time is up,
 *                                         for perf stat / perf record
 *
 * zlib's sync calls run on the main thread, so process.cpuUsage() sees all of
 * their work. The input is built exactly as node-perf-kernel.cjs builds it.
 */
const zlib = require('node:zlib');

const gzipInput = Buffer.alloc(20 * 1024 * 1024);
for (let offset = 0; offset < gzipInput.length; offset += 4) {
  gzipInput.writeUInt32LE((offset * 2654435761) % 1000, offset);
}

function cpuMsOf(work) {
  const before = process.cpuUsage();
  const result = work();
  const spent = process.cpuUsage(before);
  return { result, cpuMs: (spent.user + spent.system) / 1000 };
}

function medianOf(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.floor(sorted.length / 2)];
}

const [modeName, countText] = process.argv.slice(2);
const countValue = Number(countText);
if (!['time', 'loop'].includes(modeName) || !(countValue > 0)) {
  console.error('usage: zlib-profile.cjs time <reps> | loop <seconds>');
  process.exit(2);
}

// One untimed round so both sides start warm.
zlib.gunzipSync(zlib.gzipSync(gzipInput));

if (modeName === 'time') {
  const deflateCosts = [];
  const inflateCosts = [];
  for (let rep = 0; rep < countValue; rep++) {
    const deflated = cpuMsOf(() => zlib.gzipSync(gzipInput));
    const inflated = cpuMsOf(() => zlib.gunzipSync(deflated.result));
    if (inflated.result.length !== gzipInput.length) {
      throw new Error(`gunzip returned ${inflated.result.length} bytes, not ${gzipInput.length}`);
    }
    deflateCosts.push(deflated.cpuMs);
    inflateCosts.push(inflated.cpuMs);
  }
  const deflatedSize = zlib.gzipSync(gzipInput).length;
  console.log(JSON.stringify({
    deflate_ms: Number(medianOf(deflateCosts).toFixed(3)),
    inflate_ms: Number(medianOf(inflateCosts).toFixed(3)),
    deflated_bytes: deflatedSize,
    deflate_reps_ms: deflateCosts,
    inflate_reps_ms: inflateCosts,
  }));
} else {
  const deadline = Date.now() + countValue * 1000;
  let rounds = 0;
  while (Date.now() < deadline) {
    zlib.gunzipSync(zlib.gzipSync(gzipInput));
    rounds++;
  }
  console.log(`loop rounds=${rounds}`);
}
