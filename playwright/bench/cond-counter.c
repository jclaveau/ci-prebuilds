/*
 * Counts pthread condvar traffic per process, preloaded under either image.
 *
 * Why: musl's condvar round-trip measures 23.6 us against glibc's 9.7 us on
 * one machine (ipc-rtt-bench.c), while the socketpair round trip is at parity
 * — 14.1 us vs 14.4 — because that one is the kernel's. libWPEWebKit imports
 * all six pthread_cond_* entry points, and glib uses futex directly, so the
 * condvar traffic in a Playwright round trip is WebKit's own.
 *
 * `eval_rtt` is 500 evaluates at ~0.41 ms each and reads 1.10-1.14x, with the
 * profile ~50% idle. Four condvar round trips per evaluate would be ~56 us of
 * the difference, which is the whole gap. So the number that decides it is
 * how many there actually are, per iteration, and the counter reports per
 * process because the interesting one is the WebProcess.
 *
 * Counters live in an mmap'd file: Playwright drops a browser subprocess's
 * stderr, and WebKit SIGKILLs its auxiliary processes on close, so nothing
 * printed at exit is guaranteed to arrive. Same shape as unwind-counter.c.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

struct counters {
  unsigned long waits;
  unsigned long timedwaits;
  unsigned long signals;
  unsigned long broadcasts;
  unsigned long wait_ns;
};

static struct counters fallback;
static struct counters *counters = &fallback;

typedef int (*wait_fn)(pthread_cond_t *, pthread_mutex_t *);
typedef int (*timedwait_fn)(pthread_cond_t *, pthread_mutex_t *,
                            const struct timespec *);
typedef int (*signal_fn)(pthread_cond_t *);

__attribute__((constructor)) static void open_counters(void) {
  const char *dir = getenv("COND_OUT");
  char path[256];
  void *map;
  int fd;

  if (!dir) {
    return;
  }
  snprintf(path, sizeof(path), "%s/%d", dir, (int)getpid());
  fd = open(path, O_RDWR | O_CREAT, 0644);
  if (fd < 0) {
    return;
  }
  if (ftruncate(fd, sizeof(struct counters)) == 0) {
    map = mmap(NULL, sizeof(struct counters), PROT_READ | PROT_WRITE,
               MAP_SHARED, fd, 0);
    if (map != MAP_FAILED) {
      counters = map;
    }
  }
  close(fd);
}

static long long now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex) {
  static wait_fn real;
  long long start;
  int rc;

  if (!real) {
    real = (wait_fn)dlsym(RTLD_NEXT, "pthread_cond_wait");
  }
  __atomic_add_fetch(&counters->waits, 1, __ATOMIC_RELAXED);
  start = now_ns();
  rc = real(cond, mutex);
  __atomic_add_fetch(&counters->wait_ns, now_ns() - start, __ATOMIC_RELAXED);
  return rc;
}

int pthread_cond_timedwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                           const struct timespec *abstime) {
  static timedwait_fn real;
  long long start;
  int rc;

  if (!real) {
    real = (timedwait_fn)dlsym(RTLD_NEXT, "pthread_cond_timedwait");
  }
  __atomic_add_fetch(&counters->timedwaits, 1, __ATOMIC_RELAXED);
  start = now_ns();
  rc = real(cond, mutex, abstime);
  __atomic_add_fetch(&counters->wait_ns, now_ns() - start, __ATOMIC_RELAXED);
  return rc;
}

int pthread_cond_signal(pthread_cond_t *cond) {
  static signal_fn real;
  if (!real) {
    real = (signal_fn)dlsym(RTLD_NEXT, "pthread_cond_signal");
  }
  __atomic_add_fetch(&counters->signals, 1, __ATOMIC_RELAXED);
  return real(cond);
}

int pthread_cond_broadcast(pthread_cond_t *cond) {
  static signal_fn real;
  if (!real) {
    real = (signal_fn)dlsym(RTLD_NEXT, "pthread_cond_broadcast");
  }
  __atomic_add_fetch(&counters->broadcasts, 1, __ATOMIC_RELAXED);
  return real(cond);
}
