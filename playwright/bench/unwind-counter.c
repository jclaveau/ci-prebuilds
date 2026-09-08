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
 * Forwarding through RTLD_NEXT is safe here in a way it was not for the fmod
 * interposer: these functions are not reimplemented, only observed.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

static unsigned long throws;
static unsigned long walks;

typedef void (*throw_fn)(void *, void *, void (*)(void *));
typedef int (*trace_fn)(void *, void *);

void __cxa_throw(void *ex, void *info, void (*dest)(void *)) {
  static throw_fn real;
  __atomic_add_fetch(&throws, 1, __ATOMIC_RELAXED);
  if (!real) {
    real = (throw_fn)dlsym(RTLD_NEXT, "__cxa_throw");
  }
  real(ex, info, dest);
  __builtin_unreachable();
}

int _Unwind_Backtrace(void *trace, void *arg) {
  static trace_fn real;
  __atomic_add_fetch(&walks, 1, __ATOMIC_RELAXED);
  if (!real) {
    real = (trace_fn)dlsym(RTLD_NEXT, "_Unwind_Backtrace");
  }
  return real(trace, arg);
}

__attribute__((destructor)) static void report(void) {
  /* stderr, unbuffered by definition, because a browser subprocess is not
   * guaranteed to flush anything else on the way out. */
  fprintf(stderr, "unwind-counter pid=%d throws=%lu walks=%lu\n",
          (int)getpid(), throws, walks);
}
