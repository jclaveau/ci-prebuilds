'use strict';
// Round-trips data through node's zlib with random levels, strategies and
// write sizes, and checks zlib.crc32 against a table-driven reference. Built to
// gate zlib's crc32 SIMD target, which node leaves disabled over
// https://github.com/nodejs/node/issues/45268. Exits non-zero on the first
// mismatch, naming the seed that reproduces it.
const fs = require('fs');
const zlib = require('zlib');
const { pipeline, Readable, Writable } = require('stream');

const [inputPath, roundsArg, seedArg] = process.argv.slice(2);
const roundCount = Number(roundsArg ?? 200);
let randomState = Number(seedArg ?? Date.now()) >>> 0;
const startSeed = randomState;
if (!Number.isInteger(roundCount) || roundCount <= 0) {
  throw new Error(`rounds must be a positive integer, got ${JSON.stringify(roundsArg)}`);
}

function nextRandom() {
  randomState = (randomState + 0x6d2b79f5) >>> 0;
  let mixed = randomState;
  mixed = Math.imul(mixed ^ (mixed >>> 15), mixed | 1);
  mixed ^= mixed + Math.imul(mixed ^ (mixed >>> 7), mixed | 61);
  return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
}
const randomInt = (upperBound) => Math.floor(nextRandom() * upperBound);

const crcTable = new Uint32Array(256).map((_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value;
});
function referenceCrc32(buffer, initial = 0) {
  let crc = ~initial >>> 0;
  for (let index = 0; index < buffer.length; index++) {
    crc = crcTable[(crc ^ buffer[index]) & 0xff] ^ (crc >>> 8);
  }
  return ~crc >>> 0;
}

const realInput = fs.readFileSync(inputPath);
function makeSample() {
  const sampleSize = 1 + randomInt(4 * 1024 * 1024);
  if (randomInt(3) === 0) {
    const noise = Buffer.alloc(sampleSize);
    for (let index = 0; index < sampleSize; index++) noise[index] = randomInt(256);
    return noise;
  }
  const sliceStart = randomInt(Math.max(1, realInput.length - sampleSize));
  return realInput.subarray(sliceStart, sliceStart + sampleSize);
}

function fail(round, message) {
  console.error(`MISMATCH round ${round} (start seed ${JSON.stringify(startSeed)}): ${message}`);
  process.exit(1);
}

function streamThrough(transform, sample) {
  return new Promise((resolve, reject) => {
    const outputChunks = [];
    let readOffset = 0;
    const source = new Readable({
      read() {
        if (readOffset >= sample.length) return this.push(null);
        const chunkSize = 1 + randomInt(randomInt(2) ? 64 : 65536);
        this.push(sample.subarray(readOffset, readOffset + chunkSize));
        readOffset += chunkSize;
      },
    });
    const sink = new Writable({
      write(chunk, _encoding, next) {
        outputChunks.push(chunk);
        next();
      },
    });
    pipeline(source, transform, sink, (error) =>
      error ? reject(error) : resolve(Buffer.concat(outputChunks)));
  });
}

const strategies = [zlib.constants.Z_DEFAULT_STRATEGY, zlib.constants.Z_FILTERED,
  zlib.constants.Z_HUFFMAN_ONLY, zlib.constants.Z_RLE, zlib.constants.Z_FIXED];

// zlib.crc32 arrived in node 22.2 and 20.15; older controls get the gzip
// trailer check, which runs the same crc32.
const hasCrc32Export = typeof zlib.crc32 === 'function';
if (!hasCrc32Export) {
  console.log(`node ${process.version} has no zlib.crc32: checking the gzip trailer only`);
}

(async () => {
  for (let round = 1; round <= roundCount; round++) {
    const sample = makeSample();
    const crcOffset = randomInt(64);
    const crcSlice = sample.subarray(Math.min(crcOffset, sample.length));
    const expectedCrc = referenceCrc32(crcSlice);
    const actualCrc = hasCrc32Export ? zlib.crc32(crcSlice) : expectedCrc;
    if (actualCrc !== expectedCrc) {
      fail(round, `zlib.crc32 ${JSON.stringify(actualCrc)} vs reference ${JSON.stringify(expectedCrc)}, ` +
        `${JSON.stringify(crcSlice.length)} bytes at offset ${JSON.stringify(crcOffset)}`);
    }
    const options = { level: randomInt(10), strategy: strategies[randomInt(strategies.length)] };
    const compressed = await streamThrough(zlib.createGzip(options), sample);
    const trailerCrc = compressed.readUInt32LE(compressed.length - 8);
    if (trailerCrc !== referenceCrc32(sample)) {
      fail(round, `gzip trailer crc ${JSON.stringify(trailerCrc)} vs reference ` +
        `${JSON.stringify(referenceCrc32(sample))}, options ${JSON.stringify(options)}`);
    }
    const restored = await streamThrough(zlib.createGunzip(), compressed);
    if (!restored.equals(sample)) {
      fail(round, `gunzip gave ${JSON.stringify(restored.length)} bytes vs ` +
        `${JSON.stringify(sample.length)} sent, options ${JSON.stringify(options)}`);
    }
  }
  console.log(`zlib integrity: ${roundCount} rounds clean, start seed ${startSeed}`);
})().catch((error) => {
  console.error(`zlib integrity failed (start seed ${JSON.stringify(startSeed)}):`, error);
  process.exit(1);
});
