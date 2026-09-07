/* Candidate: reduce the exponent difference with 64/64 hardware divides,
 * shifting the DIVISOR right rather than the dividend left.
 *
 * Read out of glibc's own __fmod_finite rather than invented: it takes a
 * `xor %edx,%edx; div %rcx` — the 64-bit-dividend form — after shifting the
 * divisor down by the exponent difference, and only falls into a loop when
 * that difference exceeds the 11 bits a normalised significand has spare.
 * My first attempt fed `divq` a 128-bit dividend instead, which is the slow
 * path of the divider and measured WORSE than the bit loop it replaced.
 *
 * The identity: with M = 2^k * M', (X * 2^k) mod M == 2^k * (X mod M'). Both
 * significands are shifted up to bit 63 first, which guarantees the 11
 * trailing zeros that make each chunk worth at least 11 bits of the
 * difference — so the probe's ~21-bit case costs two divides instead of 21
 * dependent cmov iterations.
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

  if (x != x || y != y) {
    return x + y;
  }
  if (ex == 0x7ff || (uy << 1) == 0) {
    return (x * y) / (x * y);
  }
  if (ey == 0x7ff) {
    return x;
  }
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

  int d = ex - ey;
  ex = ey;

  /* Both significands up to bit 63, which is what buys the 11 spare low bits
   * every chunk below spends. The remainder stays a multiple of 2^11 by
   * construction, so the shift back down at the end is exact. */
  uint64_t mx = i << 11;
  uint64_t my = m << 11;

  mx %= my;
  while (d > 0) {
    int tz = __builtin_ctzll(my);
    int k = d < tz ? d : tz;
    mx = (mx % (my >> k)) << k;
    d -= k;
  }

  uint64_t r = mx >> 11;
  if (r == 0) {
    return to_double(sign);
  }
  while ((r & IMPLICIT) == 0) {
    r <<= 1;
    ex--;
  }
  if (ex <= 0) {
    r >>= 1 - ex;
    return to_double(sign | r);
  }
  return to_double(sign | ((uint64_t)ex << 52) | (r & MANT_MASK));
}
