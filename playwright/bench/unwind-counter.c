/*
 * Counts C++ throws and stack walks, preloaded under either image.
 *
 * Why: the launch profile spends 2.28% of ALL samples in libgcc_s on our arm
 * and under 0.17% on Playwright's — a ~13x gap in GCC's DWARF unwinder, second
 * only to the loader itself. The hot addresses (0x21a3a, 0x23296) sit in
 * .text past `_Unwind_Backtrace`, i.e. in the static CFI machinery, which
 * names the file but not the reason.
 *
 * Two reasons produce that profile and they call for opposite fixes:
 *   - exceptions actually being thrown at startup, in which case the question
 *     is what throws and whether it is our build's doing;
 *   - stack walks with no exception at all — `_Unwind_Backtrace`, as a
 *     logging or allocator hook would use — in which case the throw count
 *     stays at zero and the cost is per-walk, over a 60-DSO closure that musl
 *     iterates linearly.
 *
 * So both are counted separately rather than inferred from one number. The
 * counter reports per process, because the interesting ones are the auxiliary
 * processes WebKit spawns, not the driver.
 *
 * The counters live in an mmap'd file rather than being printed at exit. A
 * first attempt reported from a destructor onto stderr and came back "0
 * processes": Playwright pipes a browser subprocess's stderr into the driver
 * and drops it, and the auxiliary processes WebKit spawns are SIGKILLed on
 * close, so no exit-time hook of any kind is guaranteed to run. Incrementing
 * shared memory needs neither a flush nor a clean exit.
 *
 * Forwarding through RTLD_NEXT is safe here in a way it was not for the fmod
 * interposer: these functions are not reimplemented, only observed.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

struct counters {
  unsigned long throws;
  unsigned long walks;
};

static struct counters fallback;
static struct counters *counters = &fallback;

typedef void (*throw_fn)(void *, void *, void (*)(void *));
typedef int (*trace_fn)(void *, void *);

__attribute__((constructor)) static void open_counters(void) {
  const char *dir = getenv("UNWIND_OUT");
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

void __cxa_throw(void *ex, void *info, void (*dest)(void *)) {
  static throw_fn real;
  __atomic_add_fetch(&counters->throws, 1, __ATOMIC_RELAXED);
  if (!real) {
    real = (throw_fn)dlsym(RTLD_NEXT, "__cxa_throw");
  }
  real(ex, info, dest);
  __builtin_unreachable();
}

int _Unwind_Backtrace(void *trace, void *arg) {
  static trace_fn real;
  __atomic_add_fetch(&counters->walks, 1, __ATOMIC_RELAXED);
  if (!real) {
    real = (trace_fn)dlsym(RTLD_NEXT, "_Unwind_Backtrace");
  }
  return real(trace, arg);
}
