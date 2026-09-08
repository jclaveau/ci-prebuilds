/*
 * Round-trip latency for the two primitives a Playwright command travels
 * over: a socket between processes, and a condvar between threads.
 *
 * Why: `eval_rtt` is 500 `page.evaluate(() => 1)` calls and reads 1.10-1.14x,
 * `click_force` 1.20-1.24x, and both profiles are ~50% idle — the time is
 * spent waiting, not computing. WebKit's own code is at parity per unit of
 * work (`layout` is 0.80x), so the suspect is what the wait costs, and musl's
 * futex-backed condvar has no adaptive spinning where glibc's does.
 *
 * Both halves are real syscall traffic, so there is no repeat of the fmod
 * microbench that gcc constant-folded into measuring nothing: the compiler
 * cannot elide a write() the other side is blocking on. The pairs are
 * pinned to one CPU on purpose — a cross-core wakeup measures the scheduler's
 * migration policy instead of the primitive.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long long now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void pin_to_cpu0(void) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(0, &set);
  sched_setaffinity(0, sizeof(set), &set);
}

static void socket_rtt(long rounds) {
  int sv[2];
  char byte = 'x';
  long long start;
  pid_t child;
  long i;

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
    perror("socketpair");
    exit(1);
  }
  child = fork();
  if (child == 0) {
    pin_to_cpu0();
    close(sv[0]);
    for (i = 0; i < rounds; i++) {
      if (read(sv[1], &byte, 1) != 1) {
        _exit(1);
      }
      if (write(sv[1], &byte, 1) != 1) {
        _exit(1);
      }
    }
    _exit(0);
  }
  pin_to_cpu0();
  close(sv[1]);
  start = now_ns();
  for (i = 0; i < rounds; i++) {
    if (write(sv[0], &byte, 1) != 1 || read(sv[0], &byte, 1) != 1) {
      fprintf(stderr, "parent io failed\n");
      exit(1);
    }
  }
  printf("socket-rtt-ns %lld\n", (now_ns() - start) / rounds);
  close(sv[0]);
  waitpid(child, NULL, 0);
}

struct pingpong {
  pthread_mutex_t lock;
  pthread_cond_t wake;
  long turn;
  long rounds;
};

static void *responder(void *arg) {
  struct pingpong *p = arg;
  long seen = 0;

  pin_to_cpu0();
  pthread_mutex_lock(&p->lock);
  while (seen < p->rounds) {
    while (p->turn != 1) {
      pthread_cond_wait(&p->wake, &p->lock);
    }
    p->turn = 0;
    seen++;
    pthread_cond_signal(&p->wake);
  }
  pthread_mutex_unlock(&p->lock);
  return NULL;
}

static void condvar_rtt(long rounds) {
  struct pingpong p;
  pthread_t t;
  long long start;
  long i;

  pthread_mutex_init(&p.lock, NULL);
  pthread_cond_init(&p.wake, NULL);
  p.turn = 0;
  p.rounds = rounds;
  pthread_create(&t, NULL, responder, &p);

  pin_to_cpu0();
  start = now_ns();
  pthread_mutex_lock(&p.lock);
  for (i = 0; i < rounds; i++) {
    p.turn = 1;
    pthread_cond_signal(&p.wake);
    while (p.turn != 0) {
      pthread_cond_wait(&p.wake, &p.lock);
    }
  }
  pthread_mutex_unlock(&p.lock);
  printf("condvar-rtt-ns %lld\n", (now_ns() - start) / rounds);
  pthread_join(t, NULL);
}

int main(int argc, char **argv) {
  long rounds = argc > 1 ? atol(argv[1]) : 200000;

  socket_rtt(rounds);
  condvar_rtt(rounds);
  return 0;
}
