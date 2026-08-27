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

/*
 * The second shape, and the one that matters more.
 *
 * `convert8` above is a heavy vector body behind one prologue, so a canary is
 * a small fraction of it — which is exactly the reading that made the first
 * measurement say 2-7% and nearly closed the question. But `perf stat` on the
 * browser says our layout pass runs 16% MORE INSTRUCTIONS than official's at
 * 13% lower IPC, and layout is not one heavy loop: it is thousands of small
 * out-of-line calls over a box tree. A prologue is a large fraction of THAT.
 *
 * So this kernel is call-dense on purpose: small `noinline` callees, each with
 * a local array so -fstack-protector-strong applies, walked over a tree. Same
 * caveat as above about magnitude — but here the instruction COUNT is the
 * output, and a count is not a timing.
 */
#define NODES 4096

static float node_w[NODES];
static float node_h[NODES];

__attribute__((noinline))
static float measure_edge(const float *in) {
  float r[4] = { in[0], in[1], in[0] + in[1], in[0] - in[1] };
  return r[2] * 0.5f + r[3] * 0.25f;
}

__attribute__((noinline))
static float place_box(float w, float h) {
  float edge[2] = { w, h };
  return measure_edge(edge) + measure_edge(edge + 0) * 0.5f;
}

__attribute__((noinline))
static float walk(unsigned node, unsigned depth) {
  float acc[2] = { node_w[node % NODES], node_h[node % NODES] };
  float out = place_box(acc[0], acc[1]);
  if (depth) {
    out += walk(node * 2 + 1, depth - 1);
    out += walk(node * 2 + 2, depth - 1);
  }
  return out;
}

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

/*
 * Which kernel runs is an argument, because the two want different
 * instruments. `vector` is timed. `calls` is COUNTED — run it under
 * `perf stat -e instructions` and difference the counts.
 *
 * That distinction is the whole point. Timing this at all was nearly a mistake:
 * three repeats of the vector arm spread 1.782-1.868 ms, so the instrument
 * resolves about +-5%, and the effect it was asked to price was 2-7%. A
 * difference inside its own instrument's spread is not a measurement. An
 * instruction count has no such spread — it is deterministic to well under
 * 0.1% between runs of the same binary — so for "does this flag make us
 * execute more instructions", counting answers what timing cannot.
 */
int main(int argc, char **argv) {
  const char *label = argc > 1 ? argv[1] : "arm";
  const char *which = argc > 2 ? argv[2] : "vector";

  if (strcmp(which, "calls") == 0) {
    for (unsigned i = 0; i < NODES; i++) {
      node_w[i] = (float)(i % 97) + 1.0f;
      node_h[i] = (float)(i % 31) + 1.0f;
    }
    float acc = 0;
    double t0 = now_ms();
    for (unsigned r = 0; r < ROUNDS; r++) {
      acc += walk(1, 11);
    }
    printf("%s\tcalls\t%.3f ms\tchecksum %.3f\n",
           label, now_ms() - t0, acc);
    return 0;
  }

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
  printf("%s\tvector\t%.3f ms\tchecksum %.6f\n", label, best, checksum);
  return 0;
}
