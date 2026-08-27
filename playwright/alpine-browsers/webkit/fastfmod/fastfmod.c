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
 * branches. Replacing that branch with a conditional move is the whole fix;
 * the arithmetic is unchanged, which is why the result is bit-identical.
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

  /* The hot loop, and the entire point of this file. `i` is committed with a
   * conditional move, never a branch. Letting `i` reach zero is safe: 0 - m
   * stays negative forever after, so the cmov holds it at zero and the shifts
   * keep it there — which is why the zero test lives after the loop and not
   * inside it, where it would put the branch straight back. */
  for (; ex > ey; ex--) {
    uint64_t r = i - m;
    i = (r >> 63) ? i : r;
    i <<= 1;
  }
  uint64_t r = i - m;
  i = (r >> 63) ? i : r;

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
