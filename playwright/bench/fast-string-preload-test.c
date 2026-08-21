/*
 * Correctness gate for fast-string-preload.c. Runs under the same LD_PRELOAD
 * as the browser arm and exits non-zero on the first disagreement, so a shim
 * bug stops the run instead of producing a fast, corrupt browser and a number
 * nobody can attribute.
 *
 * Two properties this file has to hold, both of which it failed on the first
 * attempt and both of which make the gate pass while testing nothing:
 *
 *   - Every reference and every comparison is a hand-written byte loop.
 *     Verifying a memcpy with memcmp is the subject checking itself, and a
 *     `for` loop that copies bytes gets recognised and turned back into a
 *     memcpy call unless -fno-tree-loop-distribute-patterns says otherwise.
 *   - It must be compiled -fno-builtin. Without it the compiler inlines its
 *     own memcpy for these calls, the PLT is never taken, and the shim under
 *     test is not the code that runs. A deliberately corrupted shim passed
 *     this gate before that flag was added.
 *
 * The workflow proves both by running it three times: with no preload (the
 * control must pass), with the shim (must pass), and with a shim whose last
 * copied byte is flipped (must FAIL, or the gate is vacuous).
 */
#include <stdio.h>
#include <stddef.h>
#include <string.h>

#define CAP 4096
/* Every offset up to 40 crosses the shim's 32-byte block boundary in both
 * operands, which is where an off-by-one lives. */
#define MAX_OFF 40

static int failures;

static void fail(const char *what, size_t n, size_t off) {
  fprintf(stderr, "MISMATCH %s n=%zu off=%zu\n", what, n, off);
  failures++;
}

static void ref_copy(unsigned char *d, const unsigned char *s, size_t n) {
  for (size_t i = 0; i < n; i++) {
    d[i] = s[i];
  }
}

static void ref_fill(unsigned char *d, unsigned char c, size_t n) {
  for (size_t i = 0; i < n; i++) {
    d[i] = c;
  }
}

static int ref_equal(const unsigned char *a, const unsigned char *b, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (a[i] != b[i]) {
      return 0;
    }
  }
  return 1;
}

static unsigned char src[CAP + MAX_OFF];
static unsigned char got[CAP + MAX_OFF * 4];
static unsigned char want[CAP + MAX_OFF * 4];

int main(void) {
  size_t checks = 0;

  for (size_t i = 0; i < sizeof(src); i++) {
    src[i] = (unsigned char) (i * 31 + 7);
  }

  for (size_t n = 0; n <= 200; n++) {
    for (size_t off = 0; off < MAX_OFF; off++) {
      ref_fill(got, 0xa5, sizeof(got));
      ref_fill(want, 0xa5, sizeof(want));
      memcpy(got + off, src + off, n);
      ref_copy(want + off, src + off, n);
      if (!ref_equal(got, want, sizeof(want))) {
        fail("memcpy", n, off);
      }
      checks++;

      /* Overlap in both directions: a forward-only copy corrupts one of them
       * and the damage surfaces far from here. */
      for (int dir = -1; dir <= 1; dir += 2) {
        size_t base = MAX_OFF * 2;
        ref_copy(got, src, sizeof(src));
        ref_copy(want, src, sizeof(src));
        size_t shift = off + 1;
        unsigned char *d = dir < 0 ? got + base - shift : got + base + shift;
        unsigned char *w = dir < 0 ? want + base - shift : want + base + shift;
        memmove(d, got + base, n);
        /* Reference for an overlapping move: stage through a scratch buffer
         * so the direction cannot matter. */
        {
          static unsigned char tmp[CAP + MAX_OFF];
          ref_copy(tmp, want + base, n);
          ref_copy(w, tmp, n);
        }
        if (!ref_equal(got, want, sizeof(src))) {
          fail(dir < 0 ? "memmove-back" : "memmove-fwd", n, off);
        }
        checks++;
      }

      memset(got + off, (int) (n & 0xff), n);
      for (size_t i = 0; i < n; i++) {
        if (got[off + i] != (unsigned char) (n & 0xff)) {
          fail("memset", n, off);
          break;
        }
      }
      checks++;

      /* memcmp has to report the SIGN of the first differing byte, not just
       * non-zero: callers sort on it. The two bytes are pinned to literals
       * rather than derived by +1/-1 from the fixture, which wraps whenever
       * the fixture byte is 0xff and inverts the expected sign. */
      if (n > 0) {
        size_t idx = off + n / 2;
        ref_copy(got, src, n + off);
        ref_copy(want, src, n + off);
        got[idx] = 0x20;
        want[idx] = 0x10;
        if (memcmp(got + off, want + off, n) <= 0) {
          fail("memcmp-sign-pos", n, off);
        }
        got[idx] = 0x10;
        want[idx] = 0x20;
        if (memcmp(got + off, want + off, n) >= 0) {
          fail("memcmp-sign-neg", n, off);
        }
        checks++;
      }

      ref_fill(got, 'z', sizeof(got));
      got[off + n] = '\0';
      if (strlen((char *) got + off) != n) {
        fail("strlen", n, off);
      }
      checks++;
    }
  }

  if (failures) {
    fprintf(stderr, "%d mismatches\n", failures);
    return 1;
  }
  /* A gate that ran zero comparisons also prints nothing, so the count is
   * part of the pass line. */
  printf("fast-string shim OK — %zu checks\n", checks);
  return 0;
}
