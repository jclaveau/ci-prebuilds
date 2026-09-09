/*
 * AVX2 memcpy/memmove/memset/memcmp/strlen for chrome-headless-shell, loaded
 * with LD_PRELOAD by the chromium launch shim.
 *
 * Why chromium needs this and the other two browsers do not: `nm -D` shows
 * official chromium resolving these five routines internally while ours calls
 * out to musl, and musl links one implementation where glibc dispatches an
 * AVX2/ERMS variant off the CPU at load — Alpine has no IFUNC. Measured at
 * 3-30x slower for 64 B - 4 KB in isolation, which by itself proves nothing
 * about Blink; what does is the layout kernels, where preloading this takes
 * `layout_boxonly` 1.29x -> 1.25x and `layout_text` 1.20x -> 1.16x against the
 * official image on one runner, with the build, the fonts, the allocator and
 * the machine all held constant (run 34339130160).
 *
 * The bench copy this grew out of (playwright/bench/fast-string-preload.c) says
 * of itself "NOT a shipping proposal", and it was right to: it assumes AVX2
 * unconditionally, so on a host without it every process that loaded it would
 * take SIGILL at the first copy. That is the difference between the two files.
 * Here every AVX2 kernel carries __attribute__((target("avx2"))) and is reached
 * only through a dispatcher that checked __builtin_cpu_supports at load; the
 * translation unit itself is compiled WITHOUT -mavx2, so nothing outside those
 * functions can emit an AVX2 instruction. Without AVX2 the shim forwards to
 * musl's own routines and costs one indirect call.
 *
 * Two traps, both of which end in a browser that crashes rather than a number:
 *
 *   - A plain byte loop is recognised by the optimizer and turned back into a
 *     call to memcpy, which is now this function. The scalar paths are written
 *     as volatile-free explicit loops and the file is compiled -fno-builtin
 *     -fno-tree-loop-distribute-patterns.
 *   - memmove has to handle overlap in both directions. Chromium calls it on
 *     overlapping ranges; a forward-only copy corrupts silently and the failure
 *     surfaces somewhere else entirely.
 *
 * dlsym is what finds musl's originals, and dlsym itself calls into these
 * routines — so a scalar path has to work before the pointers are resolved.
 * Every fallback therefore tests its pointer and open-codes the loop when it is
 * still null, which is also what runs during the constructor itself.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <immintrin.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int have_avx2;

static void *(*real_memcpy)(void *, const void *, size_t);
static void *(*real_memmove)(void *, const void *, size_t);
static void *(*real_memset)(void *, int, size_t);
static int (*real_memcmp)(const void *, const void *, size_t);
static size_t (*real_strlen)(const char *);

/*
 * Records every process that loads this library, so a gate can prove the shim
 * is connected instead of assuming it. Chromium's renderers are where layout
 * runs; a marker file with one line is a preload that reached only the
 * launcher. Opt-in via the env var so the library stays inert when nobody is
 * looking, and silent on failure because a sandboxed renderer legitimately
 * cannot open a file — the count is a lower bound, which is the safe direction.
 */
static void record_load(void) {
  const char *path = getenv("FAST_STRING_MARKER");
  if (!path) {
    return;
  }
  int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
  if (fd < 0) {
    return;
  }
  char line[32];
  int n = snprintf(line, sizeof line, "%ld\n", (long) getpid());
  if (n > 0) {
    ssize_t ignored = write(fd, line, (size_t) n);
    (void) ignored;
  }
  close(fd);
}

__attribute__((constructor)) static void faststring_init(void) {
  /* CHS_FAST_STRING=0 forwards every routine to musl's own. It is the runtime
   * escape hatch if a build is ever suspected of miscopying, and it is how the
   * gate exercises the no-AVX2 path on hardware that has AVX2 — otherwise that
   * path would ship untested on every runner this repo can reach. */
  const char *off = getenv("CHS_FAST_STRING");
  have_avx2 = (off && off[0] == '0') ? 0 : __builtin_cpu_supports("avx2");
  real_memcpy = dlsym(RTLD_NEXT, "memcpy");
  real_memmove = dlsym(RTLD_NEXT, "memmove");
  real_memset = dlsym(RTLD_NEXT, "memset");
  real_memcmp = dlsym(RTLD_NEXT, "memcmp");
  real_strlen = dlsym(RTLD_NEXT, "strlen");
  record_load();
}

__attribute__((target("avx2"))) static void avx2_copy_fwd(
    unsigned char *d, const unsigned char *s, size_t n) {
  size_t i = 0;
  for (; i + 32 <= n; i += 32) {
    __m256i v = _mm256_loadu_si256((const __m256i *) (s + i));
    _mm256_storeu_si256((__m256i *) (d + i), v);
  }
  for (; i < n; i++) {
    d[i] = s[i];
  }
}

__attribute__((target("avx2"))) static void avx2_copy_bwd(
    unsigned char *d, const unsigned char *s, size_t n) {
  size_t i = n;
  while (i >= 32) {
    i -= 32;
    __m256i v = _mm256_loadu_si256((const __m256i *) (s + i));
    _mm256_storeu_si256((__m256i *) (d + i), v);
  }
  while (i > 0) {
    i--;
    d[i] = s[i];
  }
}

__attribute__((target("avx2"))) static void avx2_set(
    unsigned char *d, int c, size_t n) {
  __m256i v = _mm256_set1_epi8((char) c);
  size_t i = 0;
  for (; i + 32 <= n; i += 32) {
    _mm256_storeu_si256((__m256i *) (d + i), v);
  }
  for (; i < n; i++) {
    d[i] = (unsigned char) c;
  }
}

__attribute__((target("avx2"))) static int avx2_cmp(
    const unsigned char *x, const unsigned char *y, size_t n) {
  size_t i = 0;
  for (; i + 32 <= n; i += 32) {
    __m256i va = _mm256_loadu_si256((const __m256i *) (x + i));
    __m256i vb = _mm256_loadu_si256((const __m256i *) (y + i));
    /* movemask of the byte-equality vector: a zero bit is the first
     * difference, and its index is where the bytewise compare resumes. */
    unsigned mask = (unsigned) _mm256_movemask_epi8(_mm256_cmpeq_epi8(va, vb));
    if (mask != 0xffffffffu) {
      size_t off = i + (size_t) __builtin_ctz(~mask);
      return (int) x[off] - (int) y[off];
    }
  }
  for (; i < n; i++) {
    if (x[i] != y[i]) {
      return (int) x[i] - (int) y[i];
    }
  }
  return 0;
}

__attribute__((target("avx2"))) static size_t avx2_len(const unsigned char *p) {
  __m256i zero = _mm256_setzero_si256();
  size_t i = 0;
  /* Unaligned 32-byte loads can cross into an unmapped page past the
   * terminator, so the scan is aligned first and the head done bytewise. */
  while (((uintptr_t) (p + i) & 31u) != 0) {
    if (p[i] == 0) {
      return i;
    }
    i++;
  }
  for (;;) {
    __m256i v = _mm256_load_si256((const __m256i *) (p + i));
    unsigned mask = (unsigned) _mm256_movemask_epi8(_mm256_cmpeq_epi8(v, zero));
    if (mask != 0) {
      return i + (size_t) __builtin_ctz(mask);
    }
    i += 32;
  }
}

void *memcpy(void *dst, const void *src, size_t n) {
  if (have_avx2) {
    avx2_copy_fwd((unsigned char *) dst, (const unsigned char *) src, n);
    return dst;
  }
  if (real_memcpy) {
    return real_memcpy(dst, src, n);
  }
  unsigned char *d = (unsigned char *) dst;
  const unsigned char *s = (const unsigned char *) src;
  for (size_t i = 0; i < n; i++) {
    d[i] = s[i];
  }
  return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
  unsigned char *d = (unsigned char *) dst;
  const unsigned char *s = (const unsigned char *) src;
  if (d == s || n == 0) {
    return dst;
  }
  /* Backward only when the destination starts inside the source: the forward
   * loop would then read bytes it has already overwritten. */
  int overlapping = d > s && d < s + n;
  if (have_avx2) {
    if (overlapping) {
      avx2_copy_bwd(d, s, n);
    } else {
      avx2_copy_fwd(d, s, n);
    }
    return dst;
  }
  if (real_memmove) {
    return real_memmove(dst, src, n);
  }
  if (overlapping) {
    for (size_t i = n; i > 0; i--) {
      d[i - 1] = s[i - 1];
    }
  } else {
    for (size_t i = 0; i < n; i++) {
      d[i] = s[i];
    }
  }
  return dst;
}

void *memset(void *dst, int c, size_t n) {
  if (have_avx2) {
    avx2_set((unsigned char *) dst, c, n);
    return dst;
  }
  if (real_memset) {
    return real_memset(dst, c, n);
  }
  unsigned char *d = (unsigned char *) dst;
  for (size_t i = 0; i < n; i++) {
    d[i] = (unsigned char) c;
  }
  return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = (const unsigned char *) a;
  const unsigned char *y = (const unsigned char *) b;
  if (have_avx2) {
    return avx2_cmp(x, y, n);
  }
  if (real_memcmp) {
    return real_memcmp(a, b, n);
  }
  for (size_t i = 0; i < n; i++) {
    if (x[i] != y[i]) {
      return (int) x[i] - (int) y[i];
    }
  }
  return 0;
}

size_t strlen(const char *s) {
  if (have_avx2) {
    return avx2_len((const unsigned char *) s);
  }
  if (real_strlen) {
    return real_strlen(s);
  }
  size_t i = 0;
  while (s[i] != 0) {
    i++;
  }
  return i;
}
