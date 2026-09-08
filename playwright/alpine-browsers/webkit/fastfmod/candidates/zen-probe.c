/*
 * Why glibc's fmod gains more from Zen 4 than our shim does: the same 9M-call
 * operand stream the runtime probe's `libm_fmod` kernel produces, run against
 * the shipped shim, two variants of it and the platform's own fmod, plus a
 * raw 64-bit DIV ladder at the exact operand widths each implementation feeds
 * the divider. All in one process on one core, with the CPU model printed,
 * because this repo's fmod ratios do not transfer across runner silicon.
 *
 * The stream: x = i * 2654435761 (double), y = 4294967291, i in 1..9e6. The
 * exponent difference is 12..23 for 99.96% of calls, so glibc always takes its
 * SLOW path (`cmp $0xb,%r8d; jg`) and always exits after ONE hardware divide
 * with zero Barrett iterations. Our shim also spends exactly one divide. The
 * operands differ: ours feeds a 64-bit dividend and a ~42-bit divisor, glibc
 * a ~54-bit dividend and a ~32-bit divisor.
 *
 * Every candidate is checksum-gated against the platform's own fmod over the
 * same stream, so a faster wrong answer cannot report a win, and the platform
 * arm is call-counted by run-zen-probe.sh so an inlined libc cannot either.
 */
#include <stdint.h>
#include <string.h>
#define MANT_MASK 0x000fffffffffffffULL
#define IMPLICIT  0x0010000000000000ULL
#define SIGN_BIT  0x8000000000000000ULL
#define EXP_MASK  0x7ffULL
static inline uint64_t to_bits(double d){uint64_t u;memcpy(&u,&d,sizeof u);return u;}
static inline double to_double(uint64_t u){double d;memcpy(&d,&u,sizeof u);return d;}
static inline int normalise(uint64_t *sig){int s=0;while((*sig&IMPLICIT)==0){*sig<<=1;s++;}return 1-s;}
#define PROLOGUE(NAME)                                                        \
  uint64_t ux=to_bits(x),uy=to_bits(y);                                       \
  uint64_t sign=ux&SIGN_BIT;                                                  \
  int ex=(int)(ux>>52&EXP_MASK),ey=(int)(uy>>52&EXP_MASK);                    \
  if(x!=x||y!=y) return x+y;                                                  \
  if(ex==0x7ff||(uy<<1)==0) return (x*y)/(x*y);                               \
  if(ey==0x7ff) return x;                                                     \
  if((ux<<1)<(uy<<1)) return x;                                               \
  if((ux<<1)==(uy<<1)) return to_double(sign);                                \
  uint64_t i=ux&MANT_MASK, m=uy&MANT_MASK;                                    \
  if(ex==0) ex=normalise(&i); else i|=IMPLICIT;                               \
  if(ey==0) ey=normalise(&m); else m|=IMPLICIT;



/* ---- A: exactly origin/main ---- */
double cand_main(double x,double y){
  PROLOGUE(main)
  int d=ex-ey; ex=ey;
  uint64_t mx=i<<11, my=m<<11;
  uint64_t excess=mx-my; mx=(excess>>63)?mx:excess;
  while(d>0){int tz=__builtin_ctzll(my);int k=d<tz?d:tz;mx=(mx%(my>>k))<<k;d-=k;}
  i=mx>>11;
  if(i==0) return to_double(sign);
  while((i&IMPLICIT)==0){i<<=1;ex--;}
  if(ex<=0){i>>=1-ex;return to_double(sign|i);}
  return to_double(sign|((uint64_t)ex<<52)|(i&MANT_MASK));
}

/* ---- B: main + branchless normalisation (clz instead of the shift loop) ---- */
double cand_clz(double x,double y){
  PROLOGUE(clz)
  int d=ex-ey; ex=ey;
  uint64_t mx=i<<11, my=m<<11;
  uint64_t excess=mx-my; mx=(excess>>63)?mx:excess;
  while(d>0){int tz=__builtin_ctzll(my);int k=d<tz?d:tz;mx=(mx%(my>>k))<<k;d-=k;}
  i=mx>>11;
  if(i==0) return to_double(sign);
  int sh=__builtin_clzll(i)-11;      /* i<2^53 so clz>=11 */
  i<<=sh; ex-=sh;
  if(ex<=0){i>>=1-ex;return to_double(sign|i);}
  return to_double(sign|((uint64_t)ex<<52)|(i&MANT_MASK));
}

/* ---- C: glibc-shaped reduction: keep the significands 53-bit, spend the
 * divisor's own trailing zeros first and only then up to 11 bits of headroom
 * in the DIVIDEND, so the hardware divide sees a ~54-bit dividend instead of
 * a full 64-bit one. Same identity, same result, narrower operands. ---- */
double cand_narrow(double x,double y){
  PROLOGUE(narrow)
  int d=ex-ey; ex=ey;
  uint64_t mx=i, my=m;
  while(d>0){
    int tz=__builtin_ctzll(my);
    int rs=d<tz?d:tz;            /* free bits: shrink the modulus */
    my>>=rs; d-=rs; ex+=rs;      /* the dropped factor is a power of two */
    if(d==0) break;
    int ls=d<11?d:11;            /* paid bits: grow the dividend, <=64 total */
    mx=(mx<<ls)%my; d-=ls;
  }
  if(d==0 && mx>=my) mx%=my;     /* d exhausted by right-shifts only */
  i=mx;
  if(i==0) return to_double(sign);
  int sh=__builtin_clzll(i)-11;
  i<<=sh; ex-=sh;
  if(ex<=0){i>>=1-ex;return to_double(sign|i);}
  return to_double(sign|((uint64_t)ex<<52)|(i&MANT_MASK));
}

/* ---- D: narrow reduction, ORIGINAL shift-loop normalisation. Separates the
 * two changes in C from each other. ---- */
double cand_narrow_loop(double x,double y){
  PROLOGUE(nl)
  int d=ex-ey; ex=ey;
  uint64_t mx=i, my=m;
  while(d>0){
    int tz=__builtin_ctzll(my);
    int rs=d<tz?d:tz; my>>=rs; d-=rs; ex+=rs;
    if(d==0) break;
    int ls=d<11?d:11; mx=(mx<<ls)%my; d-=ls;
  }
  if(d==0 && mx>=my) mx%=my;
  i=mx;
  if(i==0) return to_double(sign);
  while((i&IMPLICIT)==0){i<<=1;ex--;}
  if(ex<=0){i>>=1-ex;return to_double(sign|i);}
  return to_double(sign|((uint64_t)ex<<52)|(i&MANT_MASK));
}

/* fmod candidates and a raw 64-bit DIV ladder, both on ONE core, printing the
 * CPU model. Every fmod arm is checksum-gated against the platform's own fmod
 * on the same stream, and the platform arm is call-counted, so an inlined or
 * folded arm cannot report a fast wrong number. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <stdlib.h>
static uint64_t B(double d){uint64_t u;memcpy(&u,&d,8);return u;}
static double ms(struct timespec a){struct timespec b;clock_gettime(CLOCK_MONOTONIC,&b);
  return (b.tv_sec-a.tv_sec)*1e3+(b.tv_nsec-a.tv_nsec)/1e6;}
#define N 9000000

/* Operands are generated in the loop, not read from an array: the browser's
 * JIT computes them the same way, and a 72 MB stream would price the memory
 * system beside the divider. */
static double run(double(*f)(double,double), double y, uint64_t *ck){
  struct timespec t; double best=1e18;
  for(int r=0;r<5;r++){
    uint64_t c=0; clock_gettime(CLOCK_MONOTONIC,&t);
    for(long i=1;i<N;i++) c+=B(f((double)i*2654435761.0,y));
    double e=ms(t); if(e<best)best=e; *ck=c;
  }
  return best;
}
double libc_fmod(double a,double b){return fmod(a,b);}

/* ---- raw DIV ladder ----
 * dependent chain: each divide's dividend carries 16 bits of the previous
 * remainder, so the divider cannot overlap; the mask fixes the width. */
static uint64_t divlat(uint64_t mask,uint64_t divisor,long n){
  uint64_t acc=1;
  for(long i=0;i<n;i++){ uint64_t d=mask|(acc&0xffff); acc=d%divisor; }
  return acc;
}
static uint64_t divtp(uint64_t mask,uint64_t divisor,long n){
  uint64_t a=1,b=2,c=3,e=4,s=0;
  for(long i=0;i<n;i+=4){
    s+=(mask|a)%divisor; s+=(mask|b)%divisor;
    s+=(mask|c)%divisor; s+=(mask|e)%divisor;
    a+=17;b+=19;c+=23;e+=29;
  }
  return s;
}
int main(void){
  FILE*fp=fopen("/proc/cpuinfo","r"); char L[512];
  while(fp&&fgets(L,sizeof L,fp)) if(!strncmp(L,"model name",10)){fputs(L,stdout);break;}
  if(fp)fclose(fp);
  printf("libc: %s\n",
#ifdef __GLIBC__
    "glibc"
#else
    "musl"
#endif
  );

  struct { const char*n; double(*f)(double,double); } arms[]={
    {"platform fmod",libc_fmod},{"fastfmod-main",cand_main},{"cand-clz",cand_clz},
    {"cand-narrow",cand_narrow},{"cand-narrow-loop",cand_narrow_loop}};
  struct { const char*n; double y; } streams[]={
    {"runtime-probe.cjs   y=4294967291 (prime)", 4294967291.0},
    {"wk-hotloop.cjs      y=4294967296 (2^32)",  4294967296.0}};
  for(unsigned s=0;s<2;s++){
    uint64_t ref=0,ck=0; double t0=0;
    printf("\n== %s, %d calls, best of 5 ==\n",streams[s].n,N-1);
    for(unsigned k=0;k<sizeof arms/sizeof*arms;k++){
      double t=run(arms[k].f,streams[s].y,&ck);
      if(k==0){ ref=ck; t0=t;
        printf("  %-18s %8.2f ms  %6.2fx  %5.2f ns/call  checksum %016llx\n",
               arms[k].n,t,1.0,t*1e6/(N-1),(unsigned long long)ref);
      } else {
        printf("  %-18s %8.2f ms  %6.2fx  %5.2f ns/call  %s\n",arms[k].n,t,t/t0,
               t*1e6/(N-1),ck==ref?"BIT-EXACT":"*** MISMATCH ***");
      }
    }
  }

  printf("\n== raw 64-bit DIV, 20M ops ==\n");

  struct { const char*n; uint64_t mask; uint64_t divisor; } sh[]={
    {"dvd64 dsr42 (ours)",   0x8000000000000000ULL, 0x3ffffffffffULL},
    {"dvd54 dsr32 (glibc)",  0x0020000000000000ULL, 0xfffffffbULL},
    {"dvd64 dsr32",          0x8000000000000000ULL, 0xfffffffbULL},
    {"dvd54 dsr42",          0x0020000000000000ULL, 0x3ffffffffffULL},
    {"dvd32 dsr17",          0x0000000080000000ULL, 0x1ffffULL},
    {"dvd64 dsr63",          0x8000000000000000ULL, 0x7fffffffffffffffULL}};
  struct timespec t; uint64_t sink=0;
  for(unsigned k=0;k<sizeof sh/sizeof*sh;k++){
    double bl=1e18,bt=1e18;
    for(int r=0;r<3;r++){ clock_gettime(CLOCK_MONOTONIC,&t);
      sink+=divlat(sh[k].mask,sh[k].divisor,20000000); double e=ms(t); if(e<bl)bl=e; }
    for(int r=0;r<3;r++){ clock_gettime(CLOCK_MONOTONIC,&t);
      sink+=divtp(sh[k].mask,sh[k].divisor,20000000); double e=ms(t); if(e<bt)bt=e; }
    printf("  %-22s latency %7.2f ms (%5.2f ns/div)   thruput %7.2f ms (%5.2f ns/div)\n",
           sh[k].n,bl,bl*1e6/20000000,bt,bt*1e6/20000000);
  }
  printf("(sink %llu)\n",(unsigned long long)sink);
  return 0;
}
