/* Times node's gzip_20MB row outside node: deflate (gzip wrapper, level 6,
 * as zlib.gzipSync) then inflate of the same 20 MB input, CPU time per call.
 * Prints one line per rep: "<deflate_ms> <inflate_ms> <compressed_bytes>". */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "zlib.h"

#define INPUT_BYTES (20u * 1024u * 1024u)

static double cpu_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &now);
  return now.tv_sec * 1e3 + now.tv_nsec / 1e6;
}

static void fail_with(const char *what, int code) {
  fprintf(stderr, "%s failed: %d\n", what, code);
  exit(1);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: harness <reps>\n");
    return 2;
  }
  int rep_count = atoi(argv[1]);
  unsigned char *input_bytes = malloc(INPUT_BYTES);
  /* node-perf-kernel.cjs: writeUInt32LE((offset * 2654435761) % 1000), in
   * JS doubles, so the product rounds as it does there. */
  for (uint32_t offset = 0; offset < INPUT_BYTES; offset += 4) {
    uint32_t word_value = (uint32_t)fmod((double)offset * 2654435761.0, 1000.0);
    memcpy(input_bytes + offset, &word_value, 4);
  }
  uLong packed_capacity = compressBound(INPUT_BYTES) + 64;
  unsigned char *packed_bytes = malloc(packed_capacity);
  unsigned char *unpacked_bytes = malloc(INPUT_BYTES);
  for (int rep_index = 0; rep_index < rep_count; rep_index++) {
    z_stream deflate_stream = {0};
    int status = deflateInit2(&deflate_stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                              15 + 16, 8, Z_DEFAULT_STRATEGY);
    if (status != Z_OK) fail_with("deflateInit2", status);
    deflate_stream.next_in = input_bytes;
    deflate_stream.avail_in = INPUT_BYTES;
    deflate_stream.next_out = packed_bytes;
    deflate_stream.avail_out = packed_capacity;
    double deflate_start = cpu_ms();
    status = deflate(&deflate_stream, Z_FINISH);
    double deflate_ms = cpu_ms() - deflate_start;
    if (status != Z_STREAM_END) fail_with("deflate", status);
    uLong packed_size = deflate_stream.total_out;
    deflateEnd(&deflate_stream);

    z_stream inflate_stream = {0};
    status = inflateInit2(&inflate_stream, 15 + 16);
    if (status != Z_OK) fail_with("inflateInit2", status);
    inflate_stream.next_in = packed_bytes;
    inflate_stream.avail_in = packed_size;
    inflate_stream.next_out = unpacked_bytes;
    inflate_stream.avail_out = INPUT_BYTES;
    double inflate_start = cpu_ms();
    status = inflate(&inflate_stream, Z_FINISH);
    double inflate_ms = cpu_ms() - inflate_start;
    if (status != Z_STREAM_END) fail_with("inflate", status);
    inflateEnd(&inflate_stream);
    if (memcmp(unpacked_bytes, input_bytes, INPUT_BYTES) != 0) {
      fprintf(stderr, "round trip mismatch\n");
      return 1;
    }
    printf("%.3f %.3f %lu\n", deflate_ms, inflate_ms, packed_size);
  }
  return 0;
}
