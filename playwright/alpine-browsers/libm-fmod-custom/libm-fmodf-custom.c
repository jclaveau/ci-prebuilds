/*
 * fmodf for the libm-fmod-custom preload, path chosen by exponent gap d:
 *   - d <= 8: one 32/32 divide on significands lifted to bit 31;
 *   - d <= 40: one 64/32 divl (two past d = 31), mx << d over my;
 *   - both subnormal: one 32/32 divide on the raw bits;
 *   - above, subnormal y, ey < 24 and non-finite x: 31 bits per divl, or
 *     past d = 155 a reciprocal of my and 40 bits per multiply.
 * divl is x86's 64-by-32 divide: the 32-bit divider's latency (Haswell
 * 22-29 cycles against 32-96 for 64/64) whenever the quotient fits 32 bits.
 * chrome-headless-shell's own code imports fmodf (and no fmod) from musl, so
 * fmodf is the entry that reaches chromium's calls. Firefox links it into
 * libxul, which imports fmodf from musl too.
 *
 * Every build passes -mbranches-within-32B-boundaries to the assembler (gcc
 * -Wa,..., clang directly). Without it the d <= 8 block's placement decides
 * whether a jump straddles a 32-byte line, which Skylake-family cores under
 * the JCC-erratum microcode run 1.10x slower; Haswell pays 1 cycle for it.
 *
 * Results are bit-identical to musl's; the exception flags are not in one
 * case. For a subnormal x whose remainder is +-0, musl raises x86's
 * denormal-operand flag and this code raises nothing, as libm-fmod-custom.c's
 * fmod already does.
 *
 * Kept out of libm-fmod-custom.c on purpose: V8 links that source with fmod
 * renamed, and an fmodf there would silently take over chrome's fmodf calls.
 */
#include <stdint.h>

#define SIGN_BIT_F 0x80000000u
#define MANT_MASK_F 0x007fffffu
#define IMPLICIT_F 0x00800000u
#define INF_BITS_F 0x7f800000u

static inline uint32_t float_to_bits(float f) {
  uint32_t u;
  __builtin_memcpy(&u, &f, sizeof u);
  return u;
}

static inline float bits_to_float(uint32_t u) {
  float f;
  __builtin_memcpy(&f, &u, sizeof f);
  return f;
}

/* wide_num / narrow_den for a quotient below 2^32, as narrow_rem. */
static inline uint32_t narrow_quot(uint64_t wide_num, uint32_t narrow_den) {
#if defined(__x86_64__) || defined(__i386__)
  uint32_t quot_lo;
  uint32_t rem_lo;
  __asm__("divl %4"
          : "=a"(quot_lo), "=d"(rem_lo)
          : "a"((uint32_t)wide_num), "d"((uint32_t)(wide_num >> 32)), "rm"(narrow_den));
  return quot_lo;
#else
  return (uint32_t)(wide_num / narrow_den);
#endif
}

/* wide_num % narrow_den for a quotient below 2^32: x86's 64/32 divl, the
 * 32-bit divider's speed for up to 32 more quotient bits than 32/32. */
static inline uint32_t narrow_rem(uint64_t wide_num, uint32_t narrow_den) {
#if defined(__x86_64__) || defined(__i386__)
  uint32_t quot_lo;
  uint32_t rem_lo;
  __asm__("divl %4"
          : "=a"(quot_lo), "=d"(rem_lo)
          : "a"((uint32_t)wide_num), "d"((uint32_t)(wide_num >> 32)), "rm"(narrow_den));
  return rem_lo;
#else
  return (uint32_t)(wide_num % narrow_den);
#endif
}

float fmodf(float x, float y) {
  uint32_t ux = float_to_bits(x);
  uint32_t uy = float_to_bits(y);
  uint32_t ax = ux & ~SIGN_BIT_F;
  uint32_t ay = uy & ~SIGN_BIT_F;
  uint32_t sign = ux & SIGN_BIT_F;
  if (ax < ay) {
    if (ay <= INF_BITS_F) {
      return x;
    }
  } else {
    uint32_t ex_fast = ax >> 23;
    uint32_t ey_fast = ay >> 23;
    /* y normal with ey >= 24: every nonzero remainder is a multiple of y's
     * ulp, at least 2^-126, so the result is never subnormal. */
    if (ey_fast - 24 <= 230 && ex_fast != 255) {
      uint32_t d_fast = ex_fast - ey_fast;
      if (d_fast <= 8) {
        uint32_t mx_fast = (ax << 8) | SIGN_BIT_F;
        uint32_t my_fast = (ay << 8) | SIGN_BIT_F;
        uint32_t r_fast;
        if (d_fast == 0) {
          r_fast = mx_fast - my_fast;
        } else {
          r_fast = mx_fast % (my_fast >> d_fast);
        }
        if (r_fast == 0) {
          return bits_to_float(sign);
        }
        uint32_t lz = (uint32_t)__builtin_clz(r_fast);
        return bits_to_float(sign + ((ex_fast - lz - 1) << 23) + ((r_fast << lz) >> 8));
      }
      if (d_fast <= 40) {
        uint64_t mx24 = (ax & MANT_MASK_F) | IMPLICIT_F;
        uint32_t my24 = (ay & MANT_MASK_F) | IMPLICIT_F;
        uint32_t r_mid;
        if (d_fast <= 31) {
          r_mid = narrow_rem(mx24 << d_fast, my24);
        } else {
          r_mid = narrow_rem(mx24 << (d_fast - 31), my24);
          r_mid = narrow_rem((uint64_t)r_mid << 31, my24);
        }
        if (r_mid == 0) {
          return bits_to_float(sign);
        }
        uint32_t sh = (uint32_t)__builtin_clz(r_mid) - 8;
        return bits_to_float(sign + ((ey_fast - sh - 1) << 23) + (r_mid << sh));
      }
    }
  }
  if (ay == 0 || ax >= INF_BITS_F || ay > INF_BITS_F) {
    return (x * y) / (x * y);
  }
  if (ax < ay) {
    return x;
  }
  /* Both subnormal: the bits are the significands, one 32-bit divide. */
  if (ax < IMPLICIT_F) {
    return bits_to_float(sign | (ax % ay));
  }
  int ex = (int)(ax >> 23);
  int ey = (int)(ay >> 23);
  uint64_t mx = ax & MANT_MASK_F;
  uint64_t my = ay & MANT_MASK_F;
  if (ex) {
    mx |= IMPLICIT_F;
  } else {
    ex = 1;
  }
  if (ey) {
    my |= IMPLICIT_F;
  } else {
    ey = 1;
  }
  int d = ex - ey;
  uint32_t mx32 = (uint32_t)mx;
  uint32_t my32 = (uint32_t)my;
  /* Subnormal y: bring x under y first, so every divl quotient fits. */
  if (my32 < IMPLICIT_F) {
    mx32 %= my32;
  }
  uint32_t r;
#if defined(__SIZEOF_INT128__)
  if (d > 155) {
    /* Past five divl: two divl build a 64-bit reciprocal, then each step
     * takes 40 bits with a multiply; inv_my never overestimates, so q_est
     * falls short by at most 2. */
    uint32_t inv_hi = UINT32_MAX / my32;
    uint32_t rem_hi = UINT32_MAX % my32;
    uint64_t inv_my = ((uint64_t)inv_hi << 32)
        | narrow_quot(((uint64_t)rem_hi << 32) | UINT32_MAX, my32);
    uint64_t mx64 = mx32;
    while (d > 0) {
      int step_bits = d < 40 ? d : 40;
      uint64_t wide_mx = mx64 << step_bits;
      uint64_t q_est = (uint64_t)(((unsigned __int128)wide_mx * inv_my) >> 64);
      mx64 = wide_mx - q_est * my32;
      while (mx64 >= my32) {
        mx64 -= my32;
      }
      d -= step_bits;
    }
    r = (uint32_t)mx64;
  } else
#endif
  {
    while (d > 31) {
      mx32 = narrow_rem((uint64_t)mx32 << 31, my32);
      d -= 31;
    }
    r = narrow_rem((uint64_t)mx32 << d, my32);
  }
  if (r == 0) {
    return bits_to_float(sign);
  }
  int sh = __builtin_clz(r) - 8;
  if (ey - sh >= 1) {
    return bits_to_float(sign | ((uint32_t)(ey - sh) << 23) | ((r << sh) & MANT_MASK_F));
  }
  return bits_to_float(sign | (r << (ey - 1)));
}
