'use strict';
// Preloaded (`node -r`) into the nodejs/node#45268 repro, which pipes data
// through gzip and drops the output: it only fails when glibc's malloc notices
// a damaged heap, so on musl it cannot fail. This makes the corruption visible
// without help from the allocator:
//   - every gzip stream keeps a copy of its input and output, and on end checks
//     the gzip trailer crc against a table-driven reference and the gunzipped
//     output against the input (exit 3);
//   - malloc-backed canary buffers filled with a known pattern are allocated
//     all through the run and re-checked every second and at exit (exit 4).
const zlib = require('zlib');

const crcTable = new Uint32Array(256).map((_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value;
});
function referenceCrc32(buffer) {
  let crc = 0xffffffff;
  for (let index = 0; index < buffer.length; index++) {
    crc = crcTable[(crc ^ buffer[index]) & 0xff] ^ (crc >>> 8);
  }
  return ~crc >>> 0;
}

let failureCode = 0;
function reportFailure(exitCode, message) {
  console.error(`GZIP-VERIFY FAILURE: ${message}`);
  if (!failureCode) failureCode = exitCode;
  process.exitCode = failureCode;
}

let streamCount = 0;
let verifiedCount = 0;
function verifyStream(streamNumber, inputChunks, outputChunks) {
  const sentBytes = Buffer.concat(inputChunks);
  const compressedBytes = Buffer.concat(outputChunks);
  const expectedCrc = referenceCrc32(sentBytes);
  const trailerCrc = compressedBytes.readUInt32LE(compressedBytes.length - 8);
  if (trailerCrc !== expectedCrc) {
    reportFailure(3, `stream ${JSON.stringify(streamNumber)}: gzip trailer crc ` +
      `${JSON.stringify(trailerCrc)} vs reference ${JSON.stringify(expectedCrc)}, ` +
      `${JSON.stringify(sentBytes.length)} bytes in`);
  }
  let restoredBytes;
  try {
    restoredBytes = zlib.gunzipSync(compressedBytes);
  } catch (error) {
    reportFailure(3, `stream ${JSON.stringify(streamNumber)}: gunzip threw ` +
      `${JSON.stringify(String(error))}, ${JSON.stringify(sentBytes.length)} bytes in`);
    return;
  }
  if (!restoredBytes.equals(sentBytes)) {
    reportFailure(3, `stream ${JSON.stringify(streamNumber)}: gunzip gave ` +
      `${JSON.stringify(restoredBytes.length)} bytes vs ${JSON.stringify(sentBytes.length)} sent`);
  }
  verifiedCount++;
}

// zlib's exports are read-only on newer node, so the patch goes on the Gzip
// prototype; gunzipSync below does not go through it.
const gzipRecords = new WeakMap();
function gzipRecord(gzipStream) {
  if (!gzipRecords.has(gzipStream)) {
    gzipRecords.set(gzipStream, { streamNumber: ++streamCount, inputChunks: [], outputChunks: [] });
  }
  return gzipRecords.get(gzipStream);
}
const originalTransform = zlib.Gzip.prototype._transform;
zlib.Gzip.prototype._transform = function copyingTransform(chunk, encoding, callback) {
  gzipRecord(this).inputChunks.push(Buffer.from(chunk));
  return originalTransform.call(this, chunk, encoding, callback);
};
const originalPush = zlib.Gzip.prototype.push;
zlib.Gzip.prototype.push = function copyingPush(chunk, encoding) {
  const streamRecord = gzipRecord(this);
  if (chunk === null) {
    verifyStream(streamRecord.streamNumber, streamRecord.inputChunks, streamRecord.outputChunks);
  } else {
    streamRecord.outputChunks.push(Buffer.from(chunk));
  }
  return originalPush.call(this, chunk, encoding);
};

const canaryLimit = 4000;
const canaryBuffers = [];
let canaryChecks = 0;
function canaryByte(canaryIndex) {
  return (canaryIndex * 131 + 7) & 0xff;
}
function addCanaries() {
  for (let added = 0; added < 8 && canaryBuffers.length < canaryLimit; added++) {
    const canaryIndex = canaryBuffers.length;
    // Sizes span the small and large malloc classes; allocUnsafeSlow skips
    // node's 8 KiB pool, so each canary is its own malloc block.
    const canarySize = 16 << (canaryIndex % 12);
    canaryBuffers.push(Buffer.allocUnsafeSlow(canarySize).fill(canaryByte(canaryIndex)));
  }
}
const canaryTemplates = new Map();
function canaryTemplate(canarySize, expectedByte) {
  const templateKey = `${canarySize}:${expectedByte}`;
  if (!canaryTemplates.has(templateKey)) {
    canaryTemplates.set(templateKey, Buffer.alloc(canarySize, expectedByte));
  }
  return canaryTemplates.get(templateKey);
}
function checkCanaries() {
  canaryChecks++;
  for (let canaryIndex = 0; canaryIndex < canaryBuffers.length; canaryIndex++) {
    const expectedByte = canaryByte(canaryIndex);
    const canaryBuffer = canaryBuffers[canaryIndex];
    if (canaryBuffer.equals(canaryTemplate(canaryBuffer.length, expectedByte))) continue;
    const damagedOffset = canaryBuffer.findIndex((byteValue) => byteValue !== expectedByte);
    if (damagedOffset !== -1) {
      reportFailure(4, `canary ${JSON.stringify(canaryIndex)} (${JSON.stringify(canaryBuffer.length)} ` +
        `bytes) damaged at offset ${JSON.stringify(damagedOffset)}: ` +
        `${JSON.stringify(canaryBuffer[damagedOffset])} vs ${JSON.stringify(expectedByte)}`);
      canaryBuffer.fill(expectedByte);
    }
  }
}
setInterval(addCanaries, 50).unref();
setInterval(checkCanaries, 1000).unref();

process.on('exit', () => {
  checkCanaries();
  console.error(`gzip-verify: ${JSON.stringify(verifiedCount)} of ${JSON.stringify(streamCount)} ` +
    `gzip streams verified, ${JSON.stringify(canaryBuffers.length)} canaries checked ` +
    `${JSON.stringify(canaryChecks)} times, exit ${JSON.stringify(failureCode)}`);
  if (failureCode) process.exitCode = failureCode;
});
