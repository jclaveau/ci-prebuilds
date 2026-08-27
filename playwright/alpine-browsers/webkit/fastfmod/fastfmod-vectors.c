/*
 * Drives a fixed, deterministic operand stream through whatever `fmod` the
 * loader bound, and prints a fingerprint of the RAW RESULT BITS.
 *
 * The gate runs this twice — once plain, once with libfastfmod.so preloaded —
 * and diffs the two outputs. Comparing bits rather than values means a
 * differing signed zero or NaN payload fails; comparing two runs of the SAME
 * binary means the reference is musl's own fmod rather than anything I wrote.
 *
 * Results are folded into 64 buckets so a mismatch localises to a bucket
 * instead of just saying "different", while the output stays a few hundred
 * bytes rather than a 50 MB dump.
 *
 * MUST be compiled -fno-builtin-fmod. gcc 15 expands fmod inline when the
 * divisor is a compile-time power of two, and then this program verifies
 * nothing while still linking `U fmod` from an unrelated call site — which is
 * exactly how two earlier microbenchmarks of mine "measured" a libc they
 * never called. run-gate.sh asserts the call count as well.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <stdlib.h>

#define BUCKETS 64
#define EXP_FIELD 0x7ff0000000000000ULL

static uint64_t bucket[BUCKETS];
static long checked;

static uint64_t to_bits(double d) {
  uint64_t u;
  memcpy(&u, &d, sizeof u);
  return u;
}

static double to_double(uint64_t u) {
  double d;
  memcpy(&d, &u, sizeof u);
  return d;
}

/* FNV-1a over the result bits AND both operands, so a wrong answer cannot be
 * cancelled out by a different pairing landing in the same bucket. */
static void record(double a, double b) {
  uint64_t r = to_bits(fmod(a, b));
  uint64_t h = bucket[checked % BUCKETS];
  uint64_t words[3] = {to_bits(a), to_bits(b), r};
  for (int w = 0; w < 3; w++) {
    for (int byte = 0; byte < 8; byte++) {
      h ^= (words[w] >> (byte * 8)) & 0xff;
      h *= 0x100000001b3ULL;
    }
  }
  bucket[checked % BUCKETS] = h;
  checked++;
}

static uint64_t rng = 0x243f6a8885a308d3ULL;
static uint64_t nextrand(void) {
  rng ^= rng << 13;
  rng ^= rng >> 7;
  rng ^= rng << 17;
  return rng;
}

int main(void) {
  for (int i = 0; i < BUCKETS; i++) {
    bucket[i] = 0xcbf29ce484222325ULL;
  }

  /* 1. The runtime probe's own kernel stream, which is the case that made
   *    this worth doing at all. */
  for (long i = 1; i < 300000; i++) {
    record((double)i * 2654435761.0, 4294967296.0);
  }

  /* 2. Every corner, at both signs. Zero divisor, both infinities, NaN, the
   *    smallest normal, subnormals down to DBL_TRUE_MIN, exact multiples. */
  static const double edges[] = {
      0.0,
      1.0,
      0.5,
      2.0,
      3.0,
      1024.25,
      4294967296.0,
      9007199254740992.0,
      1e308,
      2.2250738585072014e-308, /* DBL_MIN, smallest normal */
      1.1125369292536007e-308, /* half of it: subnormal */
      4.9406564584124654e-324, /* DBL_TRUE_MIN */
      1.5e-323,
      7.4e-323,
      INFINITY,
      NAN,
  };
  const int nedges = (int)(sizeof edges / sizeof *edges);
  for (int a = 0; a < nedges; a++) {
    for (int b = 0; b < nedges; b++) {
      for (int sa = 0; sa < 2; sa++) {
        for (int sb = 0; sb < 2; sb++) {
          record(sa ? -edges[a] : edges[a], sb ? -edges[b] : edges[b]);
        }
      }
    }
  }

  /* 3. Unrestricted random bit patterns: every class, in proportion. */
  for (long i = 0; i < 4000000; i++) {
    record(to_double(nextrand()), to_double(nextrand()));
  }

  /* 4. Subnormal-heavy: exponent fields forced into [0,3] on one or both
   *    sides, since class 3 only reaches a subnormal about 1 time in 2048. */
  for (long i = 0; i < 800000; i++) {
    uint64_t a = (nextrand() & ~EXP_FIELD) | ((uint64_t)(nextrand() % 4) << 52);
    uint64_t b = (nextrand() & ~EXP_FIELD) | ((uint64_t)(nextrand() % 4) << 52);
    record(to_double(a), to_double(b));
  }

  /* 5. Large exponent gaps, which is the path the cmov loop actually changes:
   *    a big dividend against a modest divisor, at both signs. */
  for (long i = 0; i < 1200000; i++) {
    double a = (double)(int64_t)(nextrand() >> 11);
    double b = (double)(uint32_t)nextrand() + 1.0;
    record(a, b);
    record(-a, b);
  }

  printf("checked=%ld\n", checked);
  for (int i = 0; i < BUCKETS; i++) {
    printf("bucket%02d=%016llx\n", i, (unsigned long long)bucket[i]);
  }

  /* Timing is informational and the gate does not fail on it. Reported so a
   * build that silently loses the speedup is still visible in the log, and
   * opt-in so the gate's two verification-only runs — the call counter and
   * the corrupted control — do not pay for 15M extra calls each. */
  if (!getenv("FASTFMOD_TIMING")) {
    return 0;
  }
  double best = 1e18;
  volatile double sink = 0;
  for (int r = 0; r < 5; r++) {
    struct timespec t0, t1;
    double s = 0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (long i = 1; i < 3000000; i++) {
      s += fmod((double)i * 2654435761.0, 4294967296.0);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    sink = s;
    double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    if (ms < best) {
      best = ms;
    }
  }
  fprintf(stderr, "kernel_best_ms=%.1f checksum=%.0f\n", best, sink);
  return 0;
}
