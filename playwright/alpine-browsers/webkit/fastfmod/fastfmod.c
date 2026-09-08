/*
 * A drop-in `fmod` for musl, preloaded under WebKit.
 *
 * Why: `libm_fmod` is the largest single per-metric gap we have on any
 * browser — 5.35x against official on an EPYC 7763, 6.3x on an EPYC 9V74,
 * 7.65x on a Xeon 8370C. It is not JSC. Both engines call libc the same
 * 3,000,000 times per kernel invocation (interposed and counted:
 * 30,000,033 ours vs 30,000,057 official), the per-call engine overhead is
 * identical, and the gap appears only when the dividend is large relative to
 * the divisor. Isolated and gated, glibc answers in 54.0 ms per 3M calls and
 * musl in 163.8 ms.
 *
 * The mechanism is musl's loop: it walks the exponent difference one bit per
 * iteration with a data-dependent branch in the body, so for operands like
 * the probe's (~21 bits of difference) every call eats ~21 unpredictable
 * branches. Removing that branch was the first fix and took musl's 372.2 ms
 * per 9M calls down to 175.0 on an EPYC 9V74 — but glibc answers the same
 * stream in 64.3, so a cmov'd bit-at-a-time loop was still 2.6x off. That
 * 2.6x IS the browser row: `libm_fmod` reads 2.60 against official on that
 * same core.
 *
 * So the bits themselves are the cost, and this now consumes up to 11 of them
 * per hardware divide instead of one per iteration. Read out of glibc's own
 * __fmod_finite rather than invented: it shifts the DIVISOR right — a
 * normalised significand always has 11 spare low bits — so the dividend never
 * outgrows 64 bits and the divide stays the fast `xor %edx; div` form. The
 * identity is M = 2^k * M' => (X * 2^k) mod M == 2^k * (X mod M'). Measured
 * at 58.7 ms, which is FASTER than glibc's own 64.3 on that core.
 *
 * Two traps, both paid for by measurement rather than avoided by reasoning:
 *   - the 128-bit `divq` form (shifting the dividend up instead of the
 *     divisor down) is the slow path of the divider, and measured WORSE than
 *     the bit loop it was meant to replace;
 *   - dividers differ enormously between cores. On an older dev box this
 *     algorithm read 247 ms against the bit loop's 241 — the ranking
 *     inverted. Zen 4's 64-bit DIV is ~19 cycles and is what the shipped
 *     images run on, so candidates are timed in CI, never locally.
 *
 * WHERE THIS ACTUALLY STANDS, per microarchitecture. Profiled in the browser
 * with wk-perf-record (both arms in one job, DSO sample share divided by the
 * rounds each arm completed), image sha-ea0b8149:
 *
 *   EPYC 7763 (Zen 3), n=3:  row 0.94,  fmod DSO 0.92-0.94   we win
 *   EPYC 9V74 (Zen 4), n=1:  row 1.11,  fmod DSO 1.16        we lose
 *
 * The row ratio tracks the fmod ratio on both, JIT sits at or below parity on
 * both, and our side resolves to a single symbol at 19.73% — so the metric is
 * this file against glibc's fmod and nothing else. Both implementations get
 * faster on Zen 4, ours 1.30x and glibc's 1.52x, so glibc gains more from the
 * newer divider rather than us standing still.
 *
 * Which contradicts the 58.7-against-64.3 above, and the contradiction is not
 * resolved: those isolated figures do not unambiguously name their core, and
 * the two instruments also disagree about absolute movement — the runtime
 * probe reads our arm FLAT across the two CPUs, the hotloop reads it gaining
 * 1.30x — while agreeing exactly on every ratio. Trust ratios measured within
 * one job; do not compare a number from one instrument against another's.
 *
 * Three explanations are dead, by measurement, so do not spend a round on
 * them again: the preload failing to reach the WebProcess (libfastfmod.so is
 * 17-20% of the profile window), a transfer gap between the isolated bench and
 * the browser (the isolated result transfers exactly on Zen 3), and the JS
 * loop hiding the difference (the kernel is ~70% fmod). What is NOT known is
 * which instruction glibc stops paying for on Zen 4; answering it needs an
 * instruction-level profile against a glibc carrying symbols, since the
 * official image ships libm stripped and its samples land on bare addresses.
 *
 * SELF-CONTAINED ON PURPOSE. An earlier prototype deferred NaN/inf/subnormal
 * corners to `fmod()`. That is fine for a normal function and catastrophic
 * for an interposer: once this object exports `fmod`, that call resolves back
 * here and recurses forever. There is deliberately no dlsym, no RTLD_NEXT and
 * no fallback path — every case is handled below.
 *
 * Correctness is not asserted, it is gated: fastfmod-vectors.c runs the same
 * operand stream with and without this object preloaded and compares the raw
 * result BITS, so a differing signed zero or NaN payload fails the build.
 * See run-gate.sh.
 */
#include <stdint.h>
#include <string.h>

#define MANT_MASK 0x000fffffffffffffULL
#define IMPLICIT  0x0010000000000000ULL
#define SIGN_BIT  0x8000000000000000ULL
#define EXP_MASK  0x7ffULL

static inline uint64_t to_bits(double d) {
  uint64_t u;
  memcpy(&u, &d, sizeof u);
  return u;
}

static inline double to_double(uint64_t u) {
  double d;
  memcpy(&d, &u, sizeof u);
  return d;
}

/* Bring a subnormal significand up so bit 52 is set, returning the exponent
 * it then corresponds to. Mirrors what the hardware would have stored had the
 * value been normal. */
static inline int normalise(uint64_t *sig) {
  int shift = 0;
  while ((*sig & IMPLICIT) == 0) {
    *sig <<= 1;
    shift++;
  }
  return 1 - shift;
}

double fmod(double x, double y) {
  uint64_t ux = to_bits(x);
  uint64_t uy = to_bits(y);
  uint64_t sign = ux & SIGN_BIT;
  int ex = (int)(ux >> 52 & EXP_MASK);
  int ey = (int)(uy >> 52 & EXP_MASK);

  /* NaN operand: propagate the FIRST one, sign and payload included, which is
   * what musl does. `x + y` gets this for free from SSE's source-operand rule.
   * Worth its own branch: the arithmetic NaN below returns the wrong SIGN for
   * fmod(NaN, -NaN) and fmod(-NaN, NaN), which is 2 cases in 1024 and was
   * caught by the bit-comparison gate rather than by reading the code. */
  if (x != x || y != y) {
    return x + y;
  }
  /* Infinite dividend or zero divisor: domain error, quiet NaN. Produced
   * arithmetically so FE_INVALID is raised the way libm raises it, rather
   * than by returning a hand-built payload. */
  if (ex == 0x7ff || (uy << 1) == 0) {
    return (x * y) / (x * y);
  }
  /* Finite dividend, infinite divisor: the dividend is the remainder. */
  if (ey == 0x7ff) {
    return x;
  }
  /* |x| < |y| leaves x untouched; |x| == |y| divides exactly. */
  if ((ux << 1) < (uy << 1)) {
    return x;
  }
  if ((ux << 1) == (uy << 1)) {
    return to_double(sign);
  }

  uint64_t i = ux & MANT_MASK;
  uint64_t m = uy & MANT_MASK;
  if (ex == 0) {
    ex = normalise(&i);
  } else {
    i |= IMPLICIT;
  }
  if (ey == 0) {
    ey = normalise(&m);
  } else {
    m |= IMPLICIT;
  }

  /* The hot loop, and the entire point of this file: (i << d) mod m, where d
   * is the exponent difference.
   *
   * Both significands are lifted to bit 63 first. That is what buys the 11
   * spare low bits in the divisor, and it is why each iteration is worth at
   * least 11 bits of d rather than one: the probe's ~21-bit case costs two
   * divides instead of 21 dependent cmovs. `ctz` is read per iteration
   * because a divisor with trailing zeros of its own gives more than 11.
   *
   * The remainder stays a multiple of 2^11 throughout — it is a remainder
   * modulo a value with 11 low zero bits — so shifting back down afterwards
   * is exact rather than a truncation. */
  int d = ex - ey;
  ex = ey;

  uint64_t mx = i << 11;
  uint64_t my = m << 11;

  /* One conditional subtract, not a divide. Both significands carry the
   * implicit bit, so mx < 2*my on entry and a single subtract establishes the
   * mx < my the loop assumes. Writing it as `mx %= my` cost a full hardware
   * divide — a third one on the probe's operands, where the reduction itself
   * needs only two — and divides are the expensive instruction here. */
  uint64_t excess = mx - my;
  mx = (excess >> 63) ? mx : excess;

  while (d > 0) {
    int tz = __builtin_ctzll(my);
    int k = d < tz ? d : tz;
    mx = (mx % (my >> k)) << k;
    d -= k;
  }
  i = mx >> 11;

  if (i == 0) {
    return to_double(sign);
  }
  while ((i & IMPLICIT) == 0) {
    i <<= 1;
    ex--;
  }
  /* A remainder can land below the normal range even when both operands are
   * normal, so denormalise rather than emitting a bogus exponent. */
  if (ex <= 0) {
    i >>= 1 - ex;
    return to_double(sign | i);
  }
  return to_double(sign | ((uint64_t)ex << 52) | (i & MANT_MASK));
}
