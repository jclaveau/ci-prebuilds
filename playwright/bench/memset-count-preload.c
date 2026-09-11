/*
 * A memset that counts instead of going faster.
 *
 * perf says `memset` inside ld-musl is the hottest symbol in our chromium by
 * 5x (run 34406201201), and the call-graph pass cannot name its callers:
 * chromium is built without frame pointers and musl writes memset in asm with
 * no CFI, so neither fp nor dwarf walks out of it. This shim answers the two
 * questions the unwinder could not, without unwinding anything.
 *
 *   Are the hot calls interposable? An LD_PRELOAD only catches calls that go
 *   through the dynamic symbol table. If the shim's `memset` takes over the
 *   samples that used to sit in ld-musl, the callers are external and the fix
 *   is a preload — the pattern already shipped for mimalloc and zlib-ng. If
 *   ld-musl stays hot, they are musl-internal and only a rebuilt libc reaches
 *   them.
 *
 *   What SIZES are they? This is the part that decides whether a faster memset
 *   is worth building at all, and it is the standing tension in the file:
 *   memset is 6.30% of samples, yet the AVX2 string shim moved the layout row
 *   by nothing and cost 4.7-5.8% on launch. Millions of 8-to-32-byte fills and
 *   a vector memset is pure call overhead — musl's scalar loop is already near
 *   optimal at that size and glibc's win is the dispatch, not the width. A few
 *   very large fills and bandwidth is the story after all.
 *
 * Constraints this file is written against, both learned the hard way:
 *
 *   - No dlsym, no libc call anywhere in `memset` itself. musl's ld.so fills
 *     memory while it is still relocating, i.e. before any lazy state in here
 *     could be initialised; two earlier interposition attempts segfaulted in
 *     exactly that window. Everything memset touches is either a parameter or
 *     static storage that the loader has already zeroed.
 *   - Compile with `-fno-builtin -fno-tree-loop-distribute-patterns`. Without
 *     them the compiler recognises the fill loops below and emits a call to
 *     `memset` — which is this function, and the process dies in unbounded
 *     recursion rather than reporting anything.
 *   - Report periodically, not only at exit. Chromium forks its renderers from
 *     the zygote (no exec, so no constructor) and SIGKILLs them on close (no
 *     destructor), and the renderer is where layout runs. The first run that
 *     reached the browser at all (34619723608) reported exactly one process,
 *     the browser, and perf put 14.5% of the samples in a renderer pid that
 *     never wrote a line. So every TICK calls the counters are written out
 *     cumulatively; the reader keeps the last line per pid.
 */
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

/* Upper bound, exclusive, of each size bucket; the last one is the catch-all.
 * Split fine below 256 bytes because that is where the answer lives: 32 is one
 * AVX2 store and 64 is a cache line, so a distribution that dies before either
 * says the width of the store was never the cost. */
#define NBUCKET 12
/* Calls between two cumulative reports from one process. */
#define TICK (1u << 17)

static void snapshot(void);
static const size_t BUCKET_MAX[NBUCKET] = {
  1, 8, 16, 32, 64, 128, 256, 1024, 4096, 65536, 1048576, (size_t) -1
};

static uint64_t total_calls;
static uint64_t total_bytes;
static uint64_t bucket_calls[NBUCKET];
static uint64_t bucket_bytes[NBUCKET];

void *memset(void *dst, int c, size_t n) {
  int b = 0;
  while (b < NBUCKET - 1 && n >= BUCKET_MAX[b]) {
    b++;
  }
  /* Relaxed: these are counters read once at exit, never used to order
   * anything, and chromium fills memory from every thread it has. A stronger
   * order would put a fence on the hottest path in the process. */
  uint64_t calls = __atomic_fetch_add(&total_calls, 1, __ATOMIC_RELAXED) + 1;
  __atomic_fetch_add(&total_bytes, (uint64_t) n, __ATOMIC_RELAXED);
  __atomic_fetch_add(&bucket_calls[b], 1, __ATOMIC_RELAXED);
  __atomic_fetch_add(&bucket_bytes[b], (uint64_t) n, __ATOMIC_RELAXED);

  unsigned char *d = (unsigned char *) dst;
  unsigned char v = (unsigned char) c;
  size_t i = 0;

  /* Word at a time, not a vector: the shim has to stay close enough to musl's
   * own cost that the profile it is measured in remains readable. A memset an
   * order of magnitude slower would inflate its own share and prove only that
   * the shim is slow. */
  if (n >= 16) {
    uint64_t w = (uint64_t) v * 0x0101010101010101ULL;
    while (((uintptr_t) (d + i) & 7) != 0) {
      d[i] = v;
      i++;
    }
    for (; i + 8 <= n; i += 8) {
      __builtin_memcpy(d + i, &w, 8);
    }
  }
  for (; i < n; i++) {
    d[i] = v;
  }
  /* The one libc excursion memset makes, and only once per TICK calls: by the
   * time any process has filled memory 2^17 times the loader is long done
   * relocating, and open/write are async-signal-safe so the thread that lands
   * on the boundary can be any thread. */
  if ((calls & (TICK - 1)) == 0) {
    snapshot();
  }
  return dst;
}

/* Hand-rolled decimal, and a single write(2), rather than stdio. The reporter
 * runs at destructor time in a process chromium may already be tearing down,
 * and snprintf calls memset — which would re-enter the counters after they
 * have been snapshotted and make the line disagree with itself. */
static char *put_u64(char *p, uint64_t v) {
  char tmp[20];
  int k = 0;
  do {
    tmp[k] = (char) ('0' + (v % 10));
    k++;
    v /= 10;
  } while (v);
  while (k > 0) {
    k--;
    *p = tmp[k];
    p++;
  }
  return p;
}

static char *put_str(char *p, const char *s) {
  while (*s) {
    *p = *s;
    p++;
    s++;
  }
  return p;
}

static char *put_comm(char *p) {
  int fd = open("/proc/self/comm", O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return put_str(p, "?");
  }
  char comm[32];
  ssize_t got = read(fd, comm, sizeof(comm) - 1);
  close(fd);
  for (ssize_t i = 0; i < got; i++) {
    if (comm[i] > ' ') {
      *p = comm[i];
      p++;
    }
  }
  return p;
}

static void emit(const char *line, size_t len) {
  /* O_APPEND, and short enough to be a single atomic write: every chromium
   * process in the tree reports into the same file at once. */
  const char *path = getenv("MEMSET_COUNT_OUT");
  int out = 2;
  if (path) {
    out = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (out < 0) {
      out = 2;
    }
  }
  ssize_t ignored = write(out, line, len);
  (void) ignored;
  if (out != 2) {
    close(out);
  }
}

/* Announce at load, separately from the counts at exit. The first dispatch of
 * this arm (run 34584573960) counted 85K calls, all of them node's and perf's,
 * and named no chromium process at all: the shipped launch wrapper does
 * `unset LD_PRELOAD` before exec, so the browser never saw the shim, and the
 * histogram read as a finding about chromium when it was a finding about
 * node. A process that loaded the shim says so here, whether or not it lives
 * long enough to reach the destructor, and the workflow refuses to read the
 * counts unless a chromium comm is among the announcements. */
__attribute__((constructor)) static void announce(void) {
  char line[128];
  char *p = line;
  p = put_str(p, "loaded pid=");
  p = put_u64(p, (uint64_t) getpid());
  p = put_str(p, " comm=");
  p = put_comm(p);
  *p = '\n';
  p++;
  emit(line, (size_t) (p - line));
}

/* One cumulative line: the counters so far, same shape whether written from
 * a tick or from the destructor, so the reader needs no second format. */
static void snapshot(void) {
  char line[512];
  char *p = line;

  p = put_str(p, "pid=");
  p = put_u64(p, (uint64_t) getpid());
  p = put_str(p, " comm=");
  p = put_comm(p);

  p = put_str(p, " calls=");
  p = put_u64(p, __atomic_load_n(&total_calls, __ATOMIC_RELAXED));
  p = put_str(p, " bytes=");
  p = put_u64(p, __atomic_load_n(&total_bytes, __ATOMIC_RELAXED));
  p = put_str(p, " hist=");
  for (int b = 0; b < NBUCKET; b++) {
    if (b) {
      p = put_str(p, ",");
    }
    p = put_u64(p, __atomic_load_n(&bucket_calls[b], __ATOMIC_RELAXED));
    p = put_str(p, ":");
    p = put_u64(p, __atomic_load_n(&bucket_bytes[b], __ATOMIC_RELAXED));
  }
  *p = '\n';
  p++;
  emit(line, (size_t) (p - line));
}

__attribute__((destructor)) static void report(void) {
  snapshot();
}
