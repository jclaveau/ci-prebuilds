/*
 * Every one of the 2^32 float x against a fixed list of divisors y: the
 * libm-fmod-custom.so's fmodf must return the same bits as the libc's own.
 *
 * run-gate.sh samples about 4M fmodf pairs. A float has only 2^32 bit
 * patterns, so for each y below the comparison covers every x there is: a
 * proof for that divisor, not a sample. Each y is picked to reach one path or
 * boundary of libm-fmodf-custom.c (d <= 8, d <= 40, the 40-bit loop, ey = 23
 * against 24, subnormal y, both subnormal, zero, inf, NaN), and x sweeps every
 * gap, sign, subnormal, inf and NaN for it.
 *
 * The reference is whatever libc this binary links: musl in the alpine job,
 * glibc in the glibc job. The subject is the .so itself, opened RTLD_LOCAL so
 * it cannot interpose on the reference; the program checks that the two
 * entries really differ before trusting a zero mismatch count.
 *
 * LIBM_FMOD_CUSTOM_FOLD_NAN=1 compares any NaN equal to any NaN. IEEE 754
 * leaves open which input's payload a NaN result carries; for two NaN inputs
 * glibc returns x's and musl (and this code) y's. The alpine job leaves it
 * unset, so against musl even the payload must match.
 *
 * MUST be compiled -fno-builtin-fmodf, or the reference call may never reach
 * libc.
 *
 * Usage: libm-fmodf-exhaustive <libm-fmod-custom.so> [y_bits_hex ...]
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const uint32_t default_divisors[] = {
    0x3f800000u, /* 1.0: every gap 0..127, all three paths, x < y */
    0x40490fdbu, /* pi: full mantissa */
    0xc0490fdbu, /* -pi: y's sign must not matter */
    0x3f7fffffu, /* largest mantissa below 1 */
    0x3fc00001u, /* 1.5 + 1 ulp */
    0x4b800000u, /* 2^24 */
    0x0c000000u, /* 2^-103, ey = 24: lowest y on the fast paths */
    0x0bffffffu, /* ey = 23: just below, takes the general path */
    0x00800000u, /* FLT_MIN */
    0x007fffffu, /* largest subnormal */
    0x00400001u, /* subnormal, both-subnormal path for small x */
    0x00000003u, /* subnormal, 2 bits */
    0x00000001u, /* FLT_TRUE_MIN: the longest loop */
    0x7f7fffffu, /* FLT_MAX */
    0x00000000u, /* +0: NaN for every x */
    0x80000000u, /* -0 */
    0x7f800000u, /* inf: x unless x is inf or NaN */
    0x7fc00000u, /* quiet NaN */
    0xffa00001u, /* negative signalling NaN */
};

typedef float (*fmodf_fn)(float, float);

static fmodf_fn custom_fmodf;
static int fold_nan;

struct sweep_slice {
  uint32_t divisor_bits;
  uint64_t first_x;
  uint64_t end_x;
  uint64_t mismatch_count;
  uint32_t first_bad_x;
  uint32_t first_bad_libc;
  uint32_t first_bad_custom;
};

static uint32_t float_bits(float f) {
  uint32_t u;
  memcpy(&u, &f, sizeof u);
  return u;
}

static float bits_float(uint32_t u) {
  float f;
  memcpy(&f, &u, sizeof f);
  return f;
}

static int is_nan_bits(uint32_t u) {
  return (u & 0x7fffffffu) > 0x7f800000u;
}

static void *sweep_slice_run(void *arg) {
  struct sweep_slice *slice = arg;
  float y = bits_float(slice->divisor_bits);
  for (uint64_t xi = slice->first_x; xi < slice->end_x; xi++) {
    float x = bits_float((uint32_t)xi);
    uint32_t libc_bits = float_bits(fmodf(x, y));
    uint32_t custom_bits = float_bits(custom_fmodf(x, y));
    if (libc_bits == custom_bits) {
      continue;
    }
    if (fold_nan && is_nan_bits(libc_bits) && is_nan_bits(custom_bits)) {
      continue;
    }
    if (slice->mismatch_count++ == 0) {
      slice->first_bad_x = (uint32_t)xi;
      slice->first_bad_libc = libc_bits;
      slice->first_bad_custom = custom_bits;
    }
  }
  return NULL;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <libm-fmod-custom.so> [y_bits_hex ...]\n", argv[0]);
    return 2;
  }
  void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!handle) {
    fprintf(stderr, "FAIL: dlopen: %s\n", dlerror());
    return 2;
  }
  custom_fmodf = (fmodf_fn)dlsym(handle, "fmodf");
  fmodf_fn libc_fmodf = (fmodf_fn)dlsym(RTLD_DEFAULT, "fmodf");
  if (!custom_fmodf || !libc_fmodf || custom_fmodf == libc_fmodf) {
    fprintf(stderr, "FAIL: the .so's fmodf is missing or is libc's own — nothing to compare\n");
    return 2;
  }
  fold_nan = getenv("LIBM_FMOD_CUSTOM_FOLD_NAN") != NULL;

  const uint32_t *divisors = default_divisors;
  int divisor_count = (int)(sizeof default_divisors / sizeof *default_divisors);
  uint32_t *given_divisors = NULL;
  if (argc > 2) {
    divisor_count = argc - 2;
    given_divisors = calloc((size_t)divisor_count, sizeof *given_divisors);
    for (int i = 0; i < divisor_count; i++) {
      given_divisors[i] = (uint32_t)strtoul(argv[i + 2], NULL, 16);
    }
    divisors = given_divisors;
  }

  long thread_count = sysconf(_SC_NPROCESSORS_ONLN);
  if (thread_count < 1) {
    thread_count = 1;
  }
  pthread_t *threads = calloc((size_t)thread_count, sizeof *threads);
  struct sweep_slice *slices = calloc((size_t)thread_count, sizeof *slices);
  const uint64_t x_space = 1ULL << 32;
  uint64_t total_mismatches = 0;

  for (int d = 0; d < divisor_count; d++) {
    for (long t = 0; t < thread_count; t++) {
      slices[t] = (struct sweep_slice){
          .divisor_bits = divisors[d],
          .first_x = x_space * (uint64_t)t / (uint64_t)thread_count,
          .end_x = x_space * (uint64_t)(t + 1) / (uint64_t)thread_count,
      };
      pthread_create(&threads[t], NULL, sweep_slice_run, &slices[t]);
    }
    uint64_t divisor_mismatches = 0;
    struct sweep_slice *first_bad = NULL;
    for (long t = 0; t < thread_count; t++) {
      pthread_join(threads[t], NULL);
      divisor_mismatches += slices[t].mismatch_count;
      if (slices[t].mismatch_count && !first_bad) {
        first_bad = &slices[t];
      }
    }
    printf("y=%08x x=all 2^32 mismatches=%llu", divisors[d],
           (unsigned long long)divisor_mismatches);
    if (first_bad) {
      printf(" first: x=%08x libc=%08x custom=%08x", first_bad->first_bad_x,
             first_bad->first_bad_libc, first_bad->first_bad_custom);
    }
    printf("\n");
    fflush(stdout);
    total_mismatches += divisor_mismatches;
  }

  printf("divisors=%d mismatches=%llu\n", divisor_count, (unsigned long long)total_mismatches);
  return total_mismatches ? 1 : 0;
}
