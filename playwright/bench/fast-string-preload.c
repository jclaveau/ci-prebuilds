/*
 * AVX2 replacements for the five routines our chrome-headless-shell imports
 * from musl, loaded with LD_PRELOAD so the SAME binary can be measured with
 * and without them. Everything else — the build, the fonts, the allocator, the
 * runner — is held constant; only which code answers `memcpy` changes.
 *
 * The question it settles: `nm -D` shows official chromium resolves these
 * internally while ours calls out to musl, and musl is 3-30x slower at
 * 64 B - 4 KB (run 32505115445). That is a fact about the routines, not proof
 * that Blink's layout path spends there. This is the lever.
 *
 * NOT a shipping proposal. If it confirms, the fix is build-side.
 *
 * Two traps this file has to dodge, both of which end in a browser that
 * crashes rather than a number:
 *
 *   - A plain byte loop is recognised by the optimizer and turned back into a
 *     call to memcpy, which is now this function. Everything is written with
 *     intrinsics and the translation unit is compiled -fno-builtin
 *     -fno-tree-loop-distribute-patterns.
 *   - memmove has to handle overlap in both directions. Chromium calls it on
 *     overlapping ranges; a forward-only copy corrupts silently and the
 *     failure surfaces somewhere else entirely.
 */
#include <fcntl.h>
#include <immintrin.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/*
 * Records every process that loads this library, so the arm can prove the
 * lever is connected instead of assuming it. Chromium's renderers are where
 * layout runs; a marker file with one line is a preload that reached only the
 * launcher, and the layout number would then be measuring nothing.
 *
 * Opt-in via the env var so the library stays inert when nobody is looking,
 * and silent on failure because a sandboxed renderer legitimately cannot open
 * a file — the count is a lower bound, which is the direction that matters.
 */
__attribute__((constructor)) static void record_load(void) {
  const char *path = getenv("FAST_STRING_MARKER");
  if (!path) {
    return;
  }
  int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0666);
  if (fd < 0) {
    return;
  }
  char line[32];
  int n = snprintf(line, sizeof(line), "%ld\n", (long) getpid());
  if (n > 0) {
    ssize_t written = write(fd, line, (size_t) n);
    (void) written;
  }
  close(fd);
}

/* Copies forward in 32-byte blocks, then a bytewise tail. Callers never see a
 * partial store because the tail is bounded by the same length. */
static inline void copy_fwd(unsigned char *d, const unsigned char *s, size_t n) {
  size_t i = 0;
  for (; i + 32 <= n; i += 32) {
    __m256i v = _mm256_loadu_si256((const __m256i *) (s + i));
    _mm256_storeu_si256((__m256i *) (d + i), v);
  }
  for (; i < n; i++) {
    d[i] = s[i];
  }
}

void *memcpy(void *dst, const void *src, size_t n) {
  copy_fwd((unsigned char *) dst, (const unsigned char *) src, n);
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
  if (d > s && d < s + n) {
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
    return dst;
  }
  copy_fwd(d, s, n);
  return dst;
}

void *memset(void *dst, int c, size_t n) {
  unsigned char *d = (unsigned char *) dst;
  __m256i v = _mm256_set1_epi8((char) c);
  size_t i = 0;
  for (; i + 32 <= n; i += 32) {
    _mm256_storeu_si256((__m256i *) (d + i), v);
  }
  for (; i < n; i++) {
    d[i] = (unsigned char) c;
  }
  return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = (const unsigned char *) a;
  const unsigned char *y = (const unsigned char *) b;
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

size_t strlen(const char *s) {
  const unsigned char *p = (const unsigned char *) s;
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
