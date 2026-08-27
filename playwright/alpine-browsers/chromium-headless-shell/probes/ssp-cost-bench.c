/*
 * What does Alpine's default -fstack-protector-strong cost a short, hot,
 * vectorised pixel conversion?
 *
 * The profile put ~73% of chromium's screenshot overrun inside two small
 * per-8-pixel conversion functions, and a disassembly of both artifacts showed
 * the same source compiled two ways: official loads the source vector straight
 * out of memory, ours realigns the stack to 32 bytes, copies the vector into a
 * local buffer, reloads it, and carries a canary. Binary-wide the artifacts
 * disagree by 10.8x on the number of canary loads, and Alpine's clang 22
 * defaults the flag ON where upstream clang defaults it off — so the flag is
 * established; what is not established is what it COSTS.
 *
 * This reproduces the shape rather than the function: a `noinline` callee that
 * takes 8 packed pixels through a local array, because that combination (small
 * callee + local array) is exactly what the canary applies to and what stops
 * the array being promoted out of memory. An isolated kernel has been wrong
 * about MAGNITUDE in this repo before, so read it as "is the lever connected
 * and which way does it point", not as a prediction of the browser's number.
 *
 *   cc -O2 -mavx2 -o bench ssp-cost-bench.c            # Alpine default: SSP on
 *   cc -O2 -mavx2 -fno-stack-protector -o bench0 ...   # what official gets
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define PIXELS (1280 * 720)
#define ROUNDS 12

static uint32_t src[PIXELS];
static float dst[PIXELS * 3];

/*
 * The artifact's shape: 10-bit channels out of a packed word, the magic
 * int-to-float sequence clang emits without AVX-512, and a real divide by a
 * float constant. noinline because the real one is not inlined either — it has
 * its own prologue, canary and epilogue in both binaries.
 */
__attribute__((noinline))
static void convert8(const uint32_t *in, float *out) {
  uint32_t px[8];
  memcpy(px, in, sizeof(px));
  for (unsigned k = 0; k < 8; k++) {
    out[k * 3 + 0] = (float)((int)((px[k] >> 0) & 0x3ff) - 384) / 510.0f;
    out[k * 3 + 1] = (float)((int)((px[k] >> 10) & 0x3ff) - 384) / 510.0f;
    out[k * 3 + 2] = (float)((int)((px[k] >> 20) & 0x3ff) - 384) / 510.0f;
  }
}

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
  const char *label = argc > 1 ? argv[1] : "arm";
  for (unsigned i = 0; i < PIXELS; i++) {
    src[i] = (i * 2654435761u) & 0x3fffffffu;
  }

  double best = 1e18;
  double checksum = 0;
  for (unsigned r = 0; r < ROUNDS; r++) {
    double t0 = now_ms();
    for (unsigned i = 0; i + 8 <= PIXELS; i += 8) {
      convert8(src + i, dst + i * 3);
    }
    double ms = now_ms() - t0;
    if (ms < best) {
      best = ms;
    }
    checksum += dst[r * 997];
  }
  // Printed so the loop cannot be optimised away, and so two arms that
  // disagree on it are not comparable in the first place.
  printf("%s\t%.3f ms\tchecksum %.6f\n", label, best, checksum);
  return 0;
}
