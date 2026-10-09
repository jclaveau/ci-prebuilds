/* fmodf on integer significands: x = mx * 2^(ex-150), y = my * 2^(ey-150),
 * subnormals taken as exponent 1 without normalising. The remainder is
 * (mx << d) % my, reduced 40 bits of gap per 64/64 divide (24 + 40 = 64). */
#include <stdint.h>

static inline uint32_t to_bits(float f) {
  uint32_t u;
  __builtin_memcpy(&u, &f, sizeof u);
  return u;
}

static inline float to_float(uint32_t u) {
  float f;
  __builtin_memcpy(&f, &u, sizeof u);
  return f;
}

float fmodf(float x, float y) {
  uint32_t ux = to_bits(x);
  uint32_t uy = to_bits(y);
  uint32_t ax = ux & 0x7fffffffu;
  uint32_t ay = uy & 0x7fffffffu;
  uint32_t sign = ux & 0x80000000u;
  if (ay == 0 || ax >= 0x7f800000u || ay > 0x7f800000u) {
    return (x * y) / (x * y);
  }
  if (ax < ay) {
    return x;
  }
  int ex = (int)(ax >> 23);
  int ey = (int)(ay >> 23);
  uint64_t mx = ax & 0x7fffffu;
  uint64_t my = ay & 0x7fffffu;
  if (ex) {
    mx |= 0x800000u;
  } else {
    ex = 1;
  }
  if (ey) {
    my |= 0x800000u;
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
    return to_float(sign);
  }
  int sh = __builtin_clz(r) - 8;
  if (ey - sh >= 1) {
    return to_float(sign | ((uint32_t)(ey - sh) << 23) | ((r << sh) & 0x7fffffu));
  }
  return to_float(sign | (r << (ey - 1)));
}
