/*
 * Counts the unwinder's entry points and its DSO scans, preloaded under
 * either image.
 *
 * Why: the launch profile spends 2.28% of ALL samples in libgcc_s on our arm
 * and under 0.17% on Playwright's — a ~13x gap in GCC's DWARF unwinder, second
 * only to the loader itself. The hot addresses (0x21a3a, 0x23296) sit in
 * .text past `_Unwind_Backtrace`, i.e. in the static CFI machinery, which
 * names the file but not the reason.
 *
 * The first version counted only `__cxa_throw` and `_Unwind_Backtrace` and
 * came back with both at zero on every process, which rules out startup
 * exceptions and explicit backtraces but leaves libgcc hot and unexplained.
 * So this counts every public way into the unwinder, plus `dl_iterate_phdr`,
 * which is how libgcc finds the FDE for a PC and is the step that scales with
 * the DSO count — 123 objects on our side, walked linearly by musl under a
 * lock. A call count alone would still not say who is asking, so the first
 * few distinct callers are resolved with dladdr and written out by name.
 *
 * Counters live in an mmap'd file rather than being printed at exit. An
 * earlier version reported from a destructor onto stderr and came back "0
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
#include <link.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

struct counters {
  unsigned long throws;
  unsigned long walks;
  unsigned long raises;
  unsigned long resumes;
  unsigned long forced;
  unsigned long phdr_scans;
};

static struct counters fallback;
static struct counters *counters = &fallback;
static char out_dir[192];

#define CALLER_SLOTS 8
static void *seen_callers[CALLER_SLOTS];
static int seen_count;

typedef void (*throw_fn)(void *, void *, void (*)(void *));
typedef int (*trace_fn)(void *, void *);
typedef int (*unwind_fn)(void *);
typedef void (*resume_fn)(void *);
typedef int (*forced_fn)(void *, void *, void *);
typedef int (*phdr_fn)(int (*)(struct dl_phdr_info *, size_t, void *), void *);

__attribute__((constructor)) static void open_counters(void) {
  const char *dir = getenv("UNWIND_OUT");
  char path[256];
  void *map;
  int fd;

  if (!dir) {
    return;
  }
  snprintf(out_dir, sizeof(out_dir), "%s", dir);
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

/* Names the caller once per distinct return address, so a hot call site costs
 * one dladdr and one append rather than one per call. */
static void note_caller(void *ret) {
  Dl_info info;
  char path[256];
  FILE *f;
  int i;

  if (!out_dir[0] || seen_count >= CALLER_SLOTS) {
    return;
  }
  for (i = 0; i < seen_count; i++) {
    if (seen_callers[i] == ret) {
      return;
    }
  }
  seen_callers[seen_count++] = ret;

  if (!dladdr(ret, &info)) {
    return;
  }
  snprintf(path, sizeof(path), "%s/callers-%d.txt", out_dir, (int)getpid());
  f = fopen(path, "a");
  if (!f) {
    return;
  }
  fprintf(f, "phdr-caller %s %s\n", info.dli_fname ? info.dli_fname : "?",
          info.dli_sname ? info.dli_sname : "?");
  fclose(f);
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

int _Unwind_RaiseException(void *ex) {
  static unwind_fn real;
  __atomic_add_fetch(&counters->raises, 1, __ATOMIC_RELAXED);
  if (!real) {
    real = (unwind_fn)dlsym(RTLD_NEXT, "_Unwind_RaiseException");
  }
  return real(ex);
}

void _Unwind_Resume(void *ex) {
  static resume_fn real;
  __atomic_add_fetch(&counters->resumes, 1, __ATOMIC_RELAXED);
  if (!real) {
    real = (resume_fn)dlsym(RTLD_NEXT, "_Unwind_Resume");
  }
  real(ex);
  __builtin_unreachable();
}

int _Unwind_ForcedUnwind(void *ex, void *stop, void *stop_arg) {
  static forced_fn real;
  __atomic_add_fetch(&counters->forced, 1, __ATOMIC_RELAXED);
  if (!real) {
    real = (forced_fn)dlsym(RTLD_NEXT, "_Unwind_ForcedUnwind");
  }
  return real(ex, stop, stop_arg);
}

int dl_iterate_phdr(int (*cb)(struct dl_phdr_info *, size_t, void *),
                    void *data) {
  static phdr_fn real;
  __atomic_add_fetch(&counters->phdr_scans, 1, __ATOMIC_RELAXED);
  note_caller(__builtin_return_address(0));
  if (!real) {
    real = (phdr_fn)dlsym(RTLD_NEXT, "dl_iterate_phdr");
  }
  return real(cb, data);
}
