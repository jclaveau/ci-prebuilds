/*
 * fastfmod with two extra reduction paths, chosen by exponent gap d:
 *   - d <= FPREM_GAP (x86_64 only, off unless defined): the x87 `fprem` loop
 *     V8 emits for JS `%` and musl ships as src/math/x86_64/fmodl.c;
 *   - d <= WIDE_GAP: fastfmod's 11-bits-per-divide loop, unchanged;
 *   - above: Rust libm's linear_mul_reduction, one divide then one
 *     64x64->128 multiply per 63 bits of gap.
 * Bit-exact against musl on fastfmod-vectors.c and a 15-gap sweep.
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


#ifndef WIDE_GAP
#define WIDE_GAP 33
#endif

typedef unsigned __int128 u128;

/* (q, r) = (hi:0) / den; caller guarantees the quotient fits 64 bits. */
static inline uint64_t div_hi(uint64_t hi, uint64_t den, uint64_t *rem) {
#if defined(__x86_64__)
  uint64_t q, r;
  __asm__("divq %4" : "=a"(q), "=d"(r) : "a"(0ULL), "d"(hi), "rm"(den));
  *rem = r;
  return q;
#else
  u128 n = (u128)hi << 64;
  *rem = (uint64_t)(n % den);
  return (uint64_t)(n / den);
#endif
}

/* (x << e) % y for wide e. Port of Rust libm's linear_mul_reduction
 * (compiler-builtins libm/src/math/support/modular.rs, MIT OR Apache-2.0).
 * Requires x < 2y and y < 2^62. One divide to set up, then one 64x64->128
 * multiply per 63 bits of gap. */
__attribute__((noinline)) static uint64_t wide_reduce(uint64_t x, uint32_t e, uint64_t y) {
  if ((y & (y - 1)) == 0) {
    return e < 64 ? (x << e) & (y - 1) : 0;
  }
  int s = __builtin_clzll(y) - 2;
  e += s;
  y <<= s;
  uint64_t m = y << 1;
  uint64_t r;
  uint64_t f = div_hi((1ULL << 63) - m, m, &r);
  uint64_t x2 = x + x;
  u128 xq2 = ((u128)x2 << 64) + (u128)x2 * f;
  while (e >= 63) {
    uint64_t u = (uint64_t)(xq2 >> 64);
    uint64_t v = (uint64_t)xq2;
    xq2 = (u128)u * r + ((u128)(v >> 1) << 64);
    e -= 63;
  }
  uint64_t a = (uint64_t)(xq2 >> 64) >> (63 - e);
  u128 b = (xq2 << e) & ~((u128)1 << 127);
  xq2 = (u128)a * r + b;
  uint64_t u = (uint64_t)(xq2 >> 64);
  uint64_t rr = (uint64_t)(((u128)m * (u + 2)) >> 64);
  if (rr >= y) {
    rr -= y;
  }
  return rr >> s;
}

static inline double pack_result(uint64_t sign, uint64_t i, int ex) {
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

__attribute__((noinline)) static double fmod_wide(uint64_t sign, int ex, uint64_t mx,
                                                  int d, uint64_t my) {
  return pack_result(sign, wide_reduce(mx, (uint32_t)d, my), ex);
}

#ifdef FPREM_GAP
/* x87 partial remainder, the loop V8 emits for JS `%` and musl ships as
 * src/math/x86_64/fmodl.c. Exact: the remainder is representable. */
static inline double fprem_mod(double x, double y) {
  long double lx = x;
  long double ly = y;
  unsigned short fpsr;
  do {
    __asm__("fprem; fnstsw %%ax" : "+t"(lx), "=a"(fpsr) : "u"(ly));
  } while (fpsr & 0x400);
  return (double)lx;
}
#endif

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

#ifdef FPREM_GAP
  if (ex - ey <= FPREM_GAP) {
    return fprem_mod(x, y);
  }
#endif
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

  if (d > WIDE_GAP) {
    return fmod_wide(sign, ex, mx, d, my);
  }

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
  return pack_result(sign, mx, ex);
}
