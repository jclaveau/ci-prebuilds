/* Per-gap ns/call, instructions and cycles for each fmodf, every result
 * bit-compared to this libc's fmodf (NaN compared as NaN), plus a uniform
 * random-bits pass. Build -fno-builtin. usage: gapf impl.so... */
#include <dlfcn.h>
#include <linux/perf_event.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define N 200000
#define REPS 7
#define RANDOM_N 20000000

typedef float (*fmodf_fn)(float, float);

static float xs[N], ys[N], ref[N], out[N];

static uint64_t rng = 0x9e3779b97f4a7c15ULL;
static uint64_t next_rand(void) {
  rng ^= rng << 13;
  rng ^= rng >> 7;
  rng ^= rng << 17;
  return rng;
}

static float make_float(int exp, uint32_t mant) {
  uint32_t bits = ((uint32_t)exp << 23) | (mant & 0x7fffffu);
  float f;
  memcpy(&f, &bits, sizeof f);
  return f;
}

static int same_result(float a, float b) {
  return (isnan(a) && isnan(b)) || memcmp(&a, &b, sizeof a) == 0;
}

static int open_counter(uint64_t config, int group) {
  struct perf_event_attr attr;
  memset(&attr, 0, sizeof attr);
  attr.size = sizeof attr;
  attr.type = PERF_TYPE_HARDWARE;
  attr.config = config;
  attr.disabled = group == -1;
  attr.exclude_kernel = 1;
  attr.exclude_hv = 1;
  return (int)syscall(SYS_perf_event_open, &attr, 0, -1, group, 0);
}

static int leader_fd = -1, cycles_fd = -1;

static void run_once(fmodf_fn f, double *ns, double *insn, double *cyc) {
  struct timespec t0, t1;
  uint64_t counts[2] = {0, 0};
  if (leader_fd >= 0) {
    ioctl(leader_fd, PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP);
    ioctl(leader_fd, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);
  }
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (int k = 0; k < N; k++) {
    out[k] = f(xs[k], ys[k]);
  }
  clock_gettime(CLOCK_MONOTONIC, &t1);
  if (leader_fd >= 0) {
    ioctl(leader_fd, PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);
    if (read(leader_fd, &counts[0], 8) != 8 || read(cycles_fd, &counts[1], 8) != 8) {
      counts[0] = counts[1] = 0;
    }
  }
  *ns = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / N;
  *insn = (double)counts[0] / N;
  *cyc = (double)counts[1] / N;
}

static int cmp_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv) {
  int gaps[] = {0, 3, 8, 12, 16, 23, 24, 32, 40, 48, 64, 100, 150, 200, 250};
  int ngaps = sizeof gaps / sizeof gaps[0];
  int nimpl = argc;
  fmodf_fn impl[16];
  const char *name[16];
  impl[0] = fmodf;
  name[0] = "libc";
  for (int a = 1; a < argc; a++) {
    void *h = dlopen(argv[a], RTLD_NOW | RTLD_LOCAL);
    if (!h || !(impl[a] = (fmodf_fn)dlsym(h, "fmodf"))) {
      fprintf(stderr, "load %s: %s\n", argv[a], dlerror());
      return 2;
    }
    name[a] = strrchr(argv[a], '/') ? strrchr(argv[a], '/') + 1 : argv[a];
  }
  leader_fd = open_counter(PERF_COUNT_HW_INSTRUCTIONS, -1);
  if (leader_fd >= 0) {
    cycles_fd = open_counter(PERF_COUNT_HW_CPU_CYCLES, leader_fd);
    if (cycles_fd < 0) {
      leader_fd = -1;
    }
  }
  printf("counters %s\n", leader_fd >= 0 ? "on" : "OFF");
  long mismatches = 0;
  /* Uniform random bit patterns: subnormals, NaN, inf, zero, every gap. */
  for (int a = 1; a < nimpl; a++) {
    uint64_t seed = rng;
    long bad = 0;
    for (long k = 0; k < RANDOM_N; k++) {
      uint64_t r = next_rand();
      uint32_t bx = (uint32_t)r, by = (uint32_t)(r >> 32);
      float x, y;
      memcpy(&x, &bx, 4);
      memcpy(&y, &by, 4);
      if (!same_result(impl[a](x, y), fmodf(x, y))) {
        if (bad < 3) {
          fprintf(stderr, "%s: fmodf(%a, %a)\n", name[a], x, y);
        }
        bad++;
      }
    }
    rng = seed;
    printf("random %-26s %ld/%d mismatches\n", name[a], bad, RANDOM_N);
    mismatches += bad;
  }
  printf("%-6s %-26s %9s %9s %9s %s\n", "gap", "impl", "ns/call", "insn", "cycles",
         "bits");
  for (int g = 0; g < ngaps; g++) {
    int d = gaps[g];
    int ey = 127 - d / 2;
    if (ey < 1) {
      ey = 1;
    }
    if (ey + d > 254) {
      ey = 254 - d;
    }
    for (int k = 0; k < N; k++) {
      xs[k] = make_float(ey + d, (uint32_t)next_rand());
      ys[k] = make_float(ey, (uint32_t)next_rand());
      if (k & 1) {
        xs[k] = -xs[k];
      }
    }
    for (int k = 0; k < N; k++) {
      ref[k] = fmodf(xs[k], ys[k]);
    }
    for (int a = 0; a < nimpl; a++) {
      double ns[REPS], insn[REPS], cyc[REPS];
      for (int r = 0; r < REPS; r++) {
        run_once(impl[a], &ns[r], &insn[r], &cyc[r]);
      }
      long bad = 0;
      for (int k = 0; k < N; k++) {
        if (!same_result(out[k], ref[k])) {
          bad++;
        }
      }
      mismatches += bad;
      qsort(ns, REPS, sizeof(double), cmp_double);
      qsort(insn, REPS, sizeof(double), cmp_double);
      qsort(cyc, REPS, sizeof(double), cmp_double);
      printf("%-6d %-26s %9.1f %9.1f %9.1f %s\n", d, name[a], ns[REPS / 2],
             insn[REPS / 2], cyc[REPS / 2], bad ? "MISMATCH" : "ok");
    }
  }
  printf("total mismatches %ld\n", mismatches);
  return mismatches != 0;
}
