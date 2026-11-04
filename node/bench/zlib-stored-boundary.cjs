'use strict';
// nodejs/node#45268's root cause, as tested by nodejs/node#67148's
// test-zlib-gzip-stored-output-boundary.js: crc_fold_copy() in zlib's
// SSE4.2+PCLMUL crc32 stored the trailing len % 16 bytes of a copy as a full
// 16-byte write, up to 15 bytes past the destination. At gzip level 0,
// deflate_stored() copies straight into the caller's output buffer, so the
// overrun lands on the heap. Output buffers here end at every offset modulo 16.
// A node with the old store aborts in glibc's malloc; one with the zmemcpy fix
// (node#52123, zlib 1.3.0.1-motley-24342f6) round-trips every case.
const zlib = require('zlib');

let caseCount = 0;
function roundTrip(input, chunkSize) {
  caseCount++;
  const restored = zlib.gunzipSync(zlib.gzipSync(input, { level: 0, chunkSize }));
  if (!restored.equals(input)) {
    console.error(`MISMATCH: ${JSON.stringify(input.length)} bytes in, ` +
      `${JSON.stringify(restored.length)} back, chunkSize ${JSON.stringify(chunkSize)}`);
    process.exit(1);
  }
}

for (let round = 0; round < 400; round++) {
  const inputSize = 40000 + round * 517;
  const input = Buffer.alloc(inputSize, round & 0xff);
  for (let offset = 0; offset < inputSize; offset += 97) input[offset] = offset & 0xff;
  roundTrip(input, 65536 + (round % 17));
}

// Small inputs finished straight into a nearly full output buffer.
for (let inputSize = 1; inputSize <= 64; inputSize++) {
  for (let chunkSize = 64; chunkSize <= 96; chunkSize++) {
    roundTrip(Buffer.alloc(inputSize, 0x61), chunkSize);
  }
}
console.log(`zlib stored boundary: ${caseCount} level-0 round trips clean`);
