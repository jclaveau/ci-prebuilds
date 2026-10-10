/*
 * Drives a fixed, deterministic operand stream through whatever `fmod` the
 * loader bound, and prints a fingerprint of the RAW RESULT BITS.
 *
 * The gate runs this twice — once plain, once with libm-fmod-custom.so preloaded —
 * and diffs the two outputs. Comparing bits rather than values means a
 * differing signed zero or NaN payload fails; comparing two runs of the SAME
 * binary means the reference is musl's own fmod rather than anything I wrote.
 *
 * Results are folded into 64 buckets so a mismatch localises to a bucket
 * instead of just saying "different", while the output stays a few hundred
 * bytes rather than a 50 MB dump.
 *
 * Classes 6-9 do the same for `fmodf`, which chromium imports from musl.
 *
 * LIBM_FMOD_CUSTOM_FOLD_NAN=1 hashes every NaN result as one canonical NaN.
 * IEEE 754 leaves open which input's payload a NaN result carries; for two
 * NaN inputs glibc returns x's and musl (and libm-fmod-custom) y's. Only the
 * glibc job sets it; against musl even the payload must match.
 *
 * MUST be compiled -fno-builtin-fmod -fno-builtin-fmodf. gcc 15 expands fmod inline when the
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
static int fold_nan;

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
  if (fold_nan && (r & ~(1ULL << 63)) > EXP_FIELD) {
    r = 0x7ff8000000000000ULL;
  }
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

static uint32_t float_bits(float f) {
  uint32_t u;
  memcpy(&u, &f, sizeof u);
  return u;
}

static float bits_float(uint32_t u) {
  float f;
  memcpy(&f, &u, sizeof f);
  return f;
}

/* record() for fmodf: same buckets, same FNV-1a, 32-bit words. */
static void record_f(float a, float b) {
  uint32_t r = float_bits(fmodf(a, b));
  if (fold_nan && (r & 0x7fffffffu) > 0x7f800000u) {
    r = 0x7fc00000u;
  }
  uint64_t h = bucket[checked % BUCKETS];
  uint32_t words[3] = {float_bits(a), float_bits(b), r};
  for (int w = 0; w < 3; w++) {
    for (int byte = 0; byte < 4; byte++) {
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
  fold_nan = getenv("LIBM_FMOD_CUSTOM_FOLD_NAN") != NULL;
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

  /* 6. fmodf corners, at both signs: FLT_MIN, subnormals down to
   *    FLT_TRUE_MIN, 2^24 and 2^-104 (ey either side of 24), exact multiples. */
  static const float edges_f[] = {
      0.0f,
      1.0f,
      0.5f,
      2.0f,
      3.0f,
      360.0f,
      1024.25f,
      16777216.0f,
      5.9604645e-08f,     /* 2^-24 */
      4.9303807e-32f,     /* 2^-104, ey = 23 */
      9.8607613e-32f,     /* 2^-103, ey = 24 */
      3.4028235e38f,      /* FLT_MAX */
      1.17549435e-38f,    /* FLT_MIN, smallest normal */
      5.877472e-39f,      /* half of it: subnormal */
      1.4e-45f,           /* FLT_TRUE_MIN */
      INFINITY,
      NAN,
  };
  const int nedges_f = (int)(sizeof edges_f / sizeof *edges_f);
  for (int a = 0; a < nedges_f; a++) {
    for (int b = 0; b < nedges_f; b++) {
      for (int sa = 0; sa < 2; sa++) {
        for (int sb = 0; sb < 2; sb++) {
          record_f(sa ? -edges_f[a] : edges_f[a], sb ? -edges_f[b] : edges_f[b]);
        }
      }
    }
  }

  /* 7. fmodf on unrestricted random bit patterns. */
  for (long i = 0; i < 2000000; i++) {
    uint64_t pair = nextrand();
    record_f(bits_float((uint32_t)pair), bits_float((uint32_t)(pair >> 32)));
  }

  /* 8. fmodf, subnormal-heavy: exponent fields in [0,3] on one or both sides. */
  for (long i = 0; i < 400000; i++) {
    uint32_t a = ((uint32_t)nextrand() & ~0x7f800000u) | ((uint32_t)(nextrand() % 4) << 23);
    uint32_t b = ((uint32_t)nextrand() & ~0x7f800000u) | ((uint32_t)(nextrand() % 4) << 23);
    record_f(bits_float(a), bits_float(b));
  }

  /* 9. fmodf at every gap 0..63, divisor exponent drawn from [1,190]: every
   *    fast-path boundary (d = 8/9, 40/41, ey = 23/24) at both signs. */
  for (long i = 0; i < 1600000; i++) {
    uint32_t gap = (uint32_t)(i % 64);
    uint32_t ey = 1 + (uint32_t)(nextrand() % 190);
    uint64_t pair = nextrand();
    uint32_t b = ((uint32_t)pair & 0x007fffffu) | (ey << 23);
    uint32_t a = ((uint32_t)(pair >> 32) & 0x807fffffu) | ((ey + gap) << 23);
    record_f(bits_float(a), bits_float(b));
  }

  printf("checked=%ld\n", checked);
  for (int i = 0; i < BUCKETS; i++) {
    printf("bucket%02d=%016llx\n", i, (unsigned long long)bucket[i]);
  }

  /* Timing is informational and the gate does not fail on it. Reported so a
   * build that silently loses the speedup is still visible in the log, and
   * opt-in so the gate's two verification-only runs — the call counter and
   * the corrupted control — do not pay for 15M extra calls each. */
  if (!getenv("LIBM_FMOD_CUSTOM_TIMING")) {
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
