/*
 * fmodf for the libm-fmod-custom preload, path chosen by exponent gap d:
 *   - d <= 8: one 32/32 divide on significands lifted to bit 31;
 *   - d <= 40: one 64/64 divide, mx << d over my;
 *   - above, subnormal y, ey < 24 and non-finite x: 40 bits per divide.
 * chrome-headless-shell imports fmodf (and no fmod) from musl, so this is the
 * only libm-fmod-custom entry a preload can reach in chromium.
 *
 * Kept out of libm-fmod-custom.c on purpose: that source is also linked into
 * Firefox's libxul and V8, where a new global fmodf would change those builds.
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
        uint64_t my24 = (ay & MANT_MASK_F) | IMPLICIT_F;
        uint32_t r_mid = (uint32_t)((mx24 << d_fast) % my24);
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
  while (d > 40) {
    mx = (mx << 40) % my;
    d -= 40;
  }
  uint32_t r = (uint32_t)((mx << d) % my);
  if (r == 0) {
    return bits_to_float(sign);
  }
  int sh = __builtin_clz(r) - 8;
  if (ey - sh >= 1) {
    return bits_to_float(sign | ((uint32_t)(ey - sh) << 23) | ((r << sh) & MANT_MASK_F));
  }
  return bits_to_float(sign | (r << (ey - 1)));
}
