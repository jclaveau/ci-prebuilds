/* Times a candidate fmod against the platform's own, and compares result BITS
 * over a wide operand stream so a faster wrong answer cannot pass. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

double cand_fmod(double, double);

static double ms_since(struct timespec a) {
  struct timespec b;
  clock_gettime(CLOCK_MONOTONIC, &b);
  return (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
}

static uint64_t bits(double d) {
  uint64_t u;
  memcpy(&u, &d, sizeof u);
  return u;
}

static double from_bits(uint64_t u) {
  double d;
  memcpy(&d, &u, sizeof u);
  return d;
}

int main(void) {
  struct timespec t;
  volatile double acc = 0;
  double cand_ms = 1e18, libc_ms = 1e18;

  /* Five alternating rounds, best of each. A single pass either way puts one
   * implementation on a cold cache or a boosted clock: the same box reported
   * glibc at 188 ms and 275 ms in consecutive runs. */
  for (int round = 0; round < 5; round++) {
    clock_gettime(CLOCK_MONOTONIC, &t);
    for (long i = 1; i < 9000000; i++) {
      acc += cand_fmod((double)i * 2654435761.0, 4294967291.0);
    }
    double c = ms_since(t);
    if (c < cand_ms) cand_ms = c;

    clock_gettime(CLOCK_MONOTONIC, &t);
    for (long i = 1; i < 9000000; i++) {
      acc += fmod((double)i * 2654435761.0, 4294967291.0);
    }
    double l = ms_since(t);
    if (l < libc_ms) libc_ms = l;
  }

  /* Differential gate. Random-ish bit patterns, plus the corners that a
   * reimplementation gets wrong: NaN payloads, signed zeros, infinities,
   * subnormals, and equal magnitudes. */
  uint64_t state = 0x243f6a8885a308d3ULL;
  long mismatches = 0, checked = 0;
  for (long n = 0; n < 4000000; n++) {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    uint64_t a = state;
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    uint64_t b = state;
    if ((n & 15) == 0) {
      a &= 0x800fffffffffffffULL; /* subnormal dividend */
    }
    if ((n & 31) == 0) {
      b = 0x7ff0000000000000ULL; /* +inf divisor */
    }
    if ((n & 63) == 0) {
      b = a; /* equal magnitudes */
    }
    if ((n & 127) == 0) {
      b = 0; /* zero divisor */
    }
    double x = from_bits(a), y = from_bits(b);
    if (bits(cand_fmod(x, y)) != bits(fmod(x, y))) {
      if (mismatches < 4) {
        printf("  MISMATCH x=%a y=%a cand=%a libc=%a\n", x, y,
               cand_fmod(x, y), fmod(x, y));
      }
      mismatches++;
    }
    checked++;
  }

  printf("cand %7.1f ms | libc %7.1f ms | %.2fx libc | %ld/%ld bit mismatches\n",
         cand_ms, libc_ms, libc_ms / cand_ms, mismatches, checked);
  return mismatches ? 1 : 0;
}
