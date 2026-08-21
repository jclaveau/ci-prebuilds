/*
 * Sizes the libc string/memory routines, because everything cheaper has been
 * excluded: our chromium is ~1.5x official on a forced-reflow loop over a
 * subtree with NO text in it, with byte-identical fonts and PartitionAlloc
 * active on both sides (run 32502670597). Box layout is mostly moving and
 * clearing memory, and Alpine has no IFUNC — so musl resolves one
 * implementation at link time where glibc dispatches an AVX2/ERMS variant off
 * the CPU at load.
 *
 * -fno-builtin is mandatory at the call site (the Makefile-less compile line in
 * the workflow passes it): without it the compiler inlines its own copy for the
 * constant sizes and the benchmark measures codegen rather than libc.
 *
 * `nop` is not filler — it is the loop's own overhead, measured the same way, so
 * a ratio can be read as "the routine" rather than "the routine plus whatever
 * the surrounding loop cost on this compiler".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const size_t SIZES[] = { 16, 64, 256, 1024, 4096, 65536, 1048576 };
#define N_SIZES (sizeof(SIZES) / sizeof(SIZES[0]))

/* Total bytes touched per measurement, so every size does the same work and
 * the numbers are comparable down the column instead of only across a row. */
static const size_t BYTES_PER_RUN = 512u * 1024u * 1024u;

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

/* Keeps the optimizer from deleting a copy whose result nobody reads. */
static volatile unsigned char sink;

enum op { OP_NOP, OP_MEMCPY, OP_MEMMOVE, OP_MEMSET, OP_MEMCMP, OP_STRLEN };

static const char *OP_NAMES[] = { "nop", "memcpy", "memmove", "memset",
                                  "memcmp", "strlen" };
#define N_OPS (sizeof(OP_NAMES) / sizeof(OP_NAMES[0]))

/*
 * The switch is OUTSIDE the loop on purpose. Dispatching per iteration made
 * `nop` the slowest row in the table at 16 bytes, because it fell through
 * every comparison while memcpy short-circuited on the first — the benchmark
 * was measuring its own dispatch, not libc.
 *
 * BARRIER is in every loop including `nop`, so the baseline pays it too:
 * memcmp and strlen are pure and their operands never change, which is exactly
 * what a compiler hoists out of a loop.
 */
#define BARRIER() __asm__ __volatile__("" : : : "memory")

static double bench(int op, unsigned char *dst, unsigned char *src,
                    size_t cap, size_t size) {
  size_t iters = BYTES_PER_RUN / size;
  double best = 1e30;
  /* Three passes, keep the fastest: a hosted runner will occasionally steal a
   * whole scheduling quantum, and the minimum is the only statistic that is
   * not a measurement of the neighbour VM. */
  for (int pass = 0; pass < 3; pass++) {
    /*
     * Re-established per pass because the ops run in sequence over shared
     * buffers and memset fills dst with a counter byte. Left over, that made
     * memcmp differ at byte 0 and return without scanning: the row read
     * 0.002 ms for half a gigabyte of comparisons.
     */
    memset(src, 'a', cap);
    memset(dst, 'a', cap);
    /* strlen needs the terminator at exactly the size under test; both
     * buffers get it so memcmp still sees them as equal. */
    src[size - 1] = '\0';
    dst[size - 1] = '\0';

    double t0 = now_ms();
    switch (op) {
      case OP_MEMCPY:
        for (size_t i = 0; i < iters; i++) {
          memcpy(dst, src, size);
          BARRIER();
        }
        break;
      case OP_MEMMOVE:
        for (size_t i = 0; i < iters; i++) {
          memmove(dst + 1, src, size);
          BARRIER();
        }
        break;
      case OP_MEMSET:
        for (size_t i = 0; i < iters; i++) {
          memset(dst, (int) (i & 0xff), size);
          BARRIER();
        }
        break;
      case OP_MEMCMP:
        for (size_t i = 0; i < iters; i++) {
          sink = (unsigned char) memcmp(dst, src, size);
          BARRIER();
        }
        break;
      case OP_STRLEN:
        for (size_t i = 0; i < iters; i++) {
          sink = (unsigned char) strlen((char *) src);
          BARRIER();
        }
        break;
      default:
        for (size_t i = 0; i < iters; i++) {
          sink = (unsigned char) i;
          BARRIER();
        }
        break;
    }
    double ms = now_ms() - t0;
    if (ms < best) {
      best = ms;
    }
    sink = dst[size - 1];
  }
  return best;
}

int main(int argc, char **argv) {
  const char *target = argc > 1 ? argv[1] : "unknown";
  size_t cap = SIZES[N_SIZES - 1] + 64;
  unsigned char *src = malloc(cap);
  unsigned char *dst = malloc(cap);
  if (!src || !dst) {
    return 1;
  }
  /* Non-zero so strlen has to walk the whole buffer, and NUL-terminated at the
   * size under test so it walks exactly that far. */

  printf("{\n  \"target\": \"%s\",\n  \"bytes_per_run\": %zu,\n  \"ops\": {\n",
         target, BYTES_PER_RUN);
  for (size_t o = 0; o < N_OPS; o++) {
    printf("    \"%s\": {", OP_NAMES[o]);
    for (size_t s = 0; s < N_SIZES; s++) {
      size_t size = SIZES[s];
      double ms = bench((int) o, dst, src, cap, size);
      printf("%s\"%zu\": %.3f", s ? ", " : "", size, ms);
    }
    printf("}%s\n", o + 1 < N_OPS ? "," : "");
  }
  printf("  }\n}\n");
  return 0;
}
