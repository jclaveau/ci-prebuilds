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
 * at 58.7 ms against glibc's 64.3 — on an EPYC 7763. Naming the core matters:
 * that pair was read for a while as a Zen 4 result, which made it look like it
 * contradicted the browser numbers below. It does not. It is the Zen 3 half of
 * a split this file has since been rewritten to remove.
 *
 * Two traps, both paid for by measurement rather than avoided by reasoning:
 *   - the 128-bit `divq` form (shifting the dividend up instead of the
 *     divisor down) is the slow path of the divider, and measured WORSE than
 *     the bit loop it was meant to replace;
 *   - dividers differ enormously between cores. On an older dev box this
 *     algorithm read 247 ms against the bit loop's 241 — the ranking
 *     inverted, so candidates are timed in CI, never locally. (The "Zen 4's
 *     DIV is ~19 cycles" that used to be quoted here was wrong: measured, it
 *     is 14 cycles latency / 7 throughput on Zen 3 AND Zen 4.)
 *
 * WHY THE SHAPE CHANGED. The lift-to-bit-63 version won on Zen 3 and lost on
 * Zen 4 — row 0.94 on an EPYC 7763, 1.11-1.14 on an EPYC 9V74, same binary,
 * which made the verdict a function of which machine the job drew.
 *
 * It was not the divider, and it was not the divide's operand width. Both are
 * measured in candidates/zen-probe.c: `div r64` is 14 cycles latency and 7
 * throughput on both cores, a divide ladder at the two shapes agrees within
 * 0.2%, and the 9V74 is simply 11.5% lower-clocked (2.847 vs 3.216 GHz). Both
 * shapes issue exactly one divide per call here, confirmed by simulating the
 * probe's stream and independently by glibc's Barrett loop taking 0.00% of
 * profile samples.
 *
 * It was the normalisation branch. Subtract the divide's 7 cycles and the
 * remaining work goes 17.4 -> 10.8 cycles for glibc across the two cores
 * (-38%) but only 13.3 -> 10.7 for ours (-20%): a mispredict costs a fixed
 * 4 cycles on both, so a wider core cannot recover it, while glibc's longer
 * branchless chain is exactly what a wider core eats better. Hence the tail
 * below is now branchless too.
 *
 * Ratio against glibc, same runner, shipping Alpine gcc 15.2, before -> after:
 *
 *   EPYC 7763  (Zen 3)   0.85 -> 0.94
 *   EPYC 9V74  (Zen 4)   1.04 -> 0.97
 *   Xeon 6973P-C         1.12 -> 0.99
 *   Xeon 8573C           1.18 -> 0.96
 *
 * Do NOT take only the clz half: on its own it is 14% SLOWER on the 7763. The
 * narrowed reduction and the branchless tail are one change.
 *
 * Three explanations are dead, by measurement, so do not spend a round on
 * them again: the preload failing to reach the WebProcess (libfastfmod.so is
 * 17-20% of the profile window), a transfer gap between the isolated bench and
 * the browser (the isolated result transfers exactly on Zen 3), and the JS
 * loop hiding the difference (the kernel is ~70% fmod). What is still NOT
 * known is why Zen 4 runs glibc's branchless tail 38% cheaper against our
 * 20%; the mispredict accounts for about half and the rest is inferred, and
 * settling it needs PMU counters (branch-misses, stalls) on a runner rather
 * than another round of reasoning.
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
   * Significands stay at 53 bits. The reduction spends the DIVISOR's own
   * trailing zeros first — charging them against the exponent, since dropping
   * a factor of 2^rs from the modulus scales the remainder by the same factor
   * — and only then borrows up to 11 bits of headroom from the dividend,
   * which is what keeps the divide in the fast `xor %edx; div` form. This is
   * glibc's __fmod shape rather than one of ours.
   *
   * An earlier version lifted both significands to bit 63 instead. It was
   * faster on Zen 3 and slower on Zen 4, and the reason was not the divider:
   * `div r64` is 14 cycles latency / 7 throughput on BOTH, and a divide ladder
   * at the two operand shapes agrees within 0.2% because Zen's divider is
   * driven by quotient bit count, which is 21.49 bits either way. Both shapes
   * issue exactly ONE divide per call on the probe's stream. The cost was in
   * the tail below. */
  int d = ex - ey;
  ex = ey;

  uint64_t mx = i;
  uint64_t my = m;

  while (d > 0) {
    int tz = __builtin_ctzll(my);
    int rs = d < tz ? d : tz;
    my >>= rs;
    d -= rs;
    ex += rs;
    if (d == 0) {
      break;
    }
    int ls = d < 11 ? d : 11;
    mx = (mx << ls) % my;
    d -= ls;
  }
  /* Only reachable when the loop never ran (d == 0) or exited through the
   * `break`, so at most one divide, and usually none. */
  if (mx >= my) {
    mx %= my;
  }
  i = mx;

  if (i == 0) {
    return to_double(sign);
  }
  /* Branchless. The bit-at-a-time version here was a genuine coin flip on the
   * probe's stream — p=1/2, mean 1.0 iterations — and a mispredict costs a
   * FIXED 4 cycles on Zen 3 and Zen 4 alike, so a wider core cannot recover
   * it. Removing it is most of the Zen 4 fix: measured with the divide's
   * 7 cycles subtracted, glibc's branchless tail gets 38% cheaper from Zen 3
   * to Zen 4 while our branchy one got only 20%. */
  int sh = __builtin_clzll(i) - 11;
  i <<= sh;
  ex -= sh;
  /* A remainder can land below the normal range even when both operands are
   * normal, so denormalise rather than emitting a bogus exponent. */
  if (ex <= 0) {
    i >>= 1 - ex;
    return to_double(sign | i);
  }
  return to_double(sign | ((uint64_t)ex << 52) | (i & MANT_MASK));
}
