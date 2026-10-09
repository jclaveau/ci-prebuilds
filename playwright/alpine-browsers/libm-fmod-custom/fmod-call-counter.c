/*
 * Counts calls that actually reach libc's `fmod`. This exists because a
 * verification run that never calls fmod passes trivially, and looks exactly
 * like a run that passed for real.
 *
 * gcc 15 expands `fmod` inline when the divisor is a compile-time power of
 * two. Under that expansion a microbenchmark reports plausible timings and a
 * differential test reports zero mismatches, while libc is never entered —
 * and `nm -D` still shows `U fmod` from some unrelated call site, so the
 * obvious check confirms a call the hot loop never makes. Two of my own
 * benchmarks did precisely this before it was caught.
 *
 * run-gate.sh preloads this and requires a minimum call count before it will
 * accept the verification as meaningful.
 *
 * Do NOT use this to time anything: the two clock_gettime calls cost roughly
 * 65 ns per invocation and swamp the effect under measurement. The count is
 * the trustworthy output.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static double (*real_fmod)(double, double);
static unsigned long long calls;

__attribute__((constructor)) static void init(void) {
  real_fmod = (double (*)(double, double))dlsym(RTLD_NEXT, "fmod");
}

__attribute__((destructor)) static void dump(void) {
  const char *out = getenv("FMOD_COUNT_OUT");
  if (!out) {
    return;
  }
  char path[512];
  snprintf(path, sizeof path, "%s.%d", out, (int)getpid());
  FILE *f = fopen(path, "w");
  if (!f) {
    return;
  }
  fprintf(f, "%llu\n", calls);
  fclose(f);
}

double fmod(double x, double y) {
  if (!real_fmod) {
    real_fmod = (double (*)(double, double))dlsym(RTLD_NEXT, "fmod");
  }
  calls++;
  return real_fmod(x, y);
}
