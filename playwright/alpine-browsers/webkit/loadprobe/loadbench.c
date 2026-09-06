/*
 * Times what `launch` mostly is: mapping libWPEWebKit and processing its
 * ~320,000 relocations. RTLD_NOW vs RTLD_LAZY is the same distinction as the
 * BIND_NOW flag ours links and official's does not, tested inside one process
 * so nothing else varies.
 *
 * Prints a non-vacuity witness (the resolved address of a known symbol), since
 * a dlopen that silently failed would otherwise report a very fast load.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
  const char *path = argv[1];
  int mode = (argc > 2 && argv[2][0] == 'n') ? RTLD_NOW : RTLD_LAZY;

  double t0 = now_ms();
  void *h = dlopen(path, mode);
  double t1 = now_ms();
  if (!h) {
    printf("FAILED: %s\n", dlerror());
    return 1;
  }
  void *sym = dlsym(h, "wpe_view_backend_create");
  printf("%-5s %8.1f ms   witness=%s\n", mode == RTLD_NOW ? "NOW" : "LAZY", t1 - t0,
         sym ? "resolved" : "MISSING");
  return sym ? 0 : 2;
}
