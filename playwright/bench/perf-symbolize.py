#!/usr/bin/env python3
"""Name the hot addresses of our stripped chromium from the link census.

Our binary ships with symbol_level = 0 and stripped, so `perf report` prints
every sample in it as `[.] 0x<offset>`. The from-source chain runs
link-census.sh between the link and the strip and keeps `symtab.nm.gz`
(llvm-nm -n -S of the linked binary), which is a full address→name map for
exactly this build. Nothing else in the pipeline has names for our side, and
official has none anywhere, so this is one-sided by construction: it says WHAT
is hot in ours, and the DSO/thread tables say how much MORE than official.

Two things have to line up for a name to be right, and both are checked here
rather than assumed:

  - perf's unresolved address is a FILE OFFSET (the map-relative address plus
    the map's pgoff), while nm prints virtual addresses. For a PIE the two
    differ by the .text LOAD segment's p_vaddr - p_offset — 0x1000 on every
    build seen so far, but read from the binary by the caller, not hardcoded.
  - the census must be the census of THIS binary. There is no build-id in it
    to compare, so the check is geometric: with the right table and shift,
    every sample lands inside [sym, sym + size) of the symbol it resolves to;
    with a foreign table a large share lands in the gap past a symbol's end.
    The share is printed, and past 5 % the whole table is labelled as
    untrustworthy rather than printed as a finding.

Per-instruction annotation of the top symbols is the pass that found the
fortify overlap check: the hot instructions inside a hot function are the
shape of the cost (a compare-and-trap after every store, a call into a
libc routine, a stall on one load), and the symbol name alone does not say.

usage: perf-symbolize.py --nm symtab.nm.gz --binary <elf> --delta 0x1000
         --report <perf report --sort comm,sym -n output> [--top 40]
         [--annotate 8] [--objdump objdump] [--title ...]
"""

import argparse
import bisect
import collections
import gzip
import re
import subprocess
import sys

# `perf report --stdio -n --sort comm,sym`, unresolved rows only.
CONTEXT = 3
ROW = re.compile(
    r'^\s*([\d.]+)%\s+(\d+)\s+(\S+)\s+\[[.k]\]\s+0x([0-9a-f]+)')


def load_census(path):
    addrs, sizes, names = [], [], []
    with gzip.open(path, 'rt') as f:
        for line in f:
            p = line.split()
            if len(p) < 4 or p[2] not in ('t', 'T', 'w', 'W'):
                continue
            addrs.append(int(p[0], 16))
            sizes.append(int(p[1], 16))
            names.append(p[3])
    return addrs, sizes, names


def demangle(names):
    if not names:
        return []
    try:
        out = subprocess.run(['c++filt'] + list(names), capture_output=True,
                             text=True, check=False).stdout.splitlines()
        if len(out) == len(names):
            return out
    except OSError:
        pass
    return list(names)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--nm', required=True)
    ap.add_argument('--binary', required=True)
    ap.add_argument('--delta', default='0x1000')
    ap.add_argument('--report', required=True)
    ap.add_argument('--top', type=int, default=40)
    ap.add_argument('--annotate', type=int, default=8)
    ap.add_argument('--objdump', default='objdump')
    ap.add_argument('--title', default='')
    a = ap.parse_args()

    delta = int(a.delta, 16)
    addrs, sizes, names = load_census(a.nm)
    if not addrs:
        print(f'_census {a.nm} has no text symbols_')
        return 0

    by_addr = collections.Counter()      # vaddr -> samples
    by_comm_sym = collections.Counter()  # (comm, idx) -> samples
    total = 0
    for line in open(a.report, errors='replace'):
        m = ROW.match(line)
        if not m:
            continue
        n = int(m.group(2))
        comm = m.group(3)
        va = int(m.group(4), 16) + delta
        by_addr[va] += n
        i = bisect.bisect_right(addrs, va) - 1
        by_comm_sym[(comm, i)] += n
        total += n
    if not total:
        print('_no unresolved samples in the main binary_')
        return 0

    # The geometric check: samples past the end of the symbol they resolve to.
    past = 0
    for va, n in by_addr.items():
        i = bisect.bisect_right(addrs, va) - 1
        if i < 0 or va >= addrs[i] + sizes[i]:
            past += n
    past_pct = 100.0 * past / total
    trusted = past_pct <= 5.0

    by_sym = collections.Counter()
    for (comm, i), n in by_comm_sym.items():
        by_sym[i] += n
    top = by_sym.most_common(a.top)
    dem = demangle([names[i] if i >= 0 else '?' for i, _ in top])

    title = a.title or 'hot symbols'
    print(f'#### {title}\n')
    print(f'{total} samples in the main binary; {past_pct:.2f}% land past the '
          f'end of the symbol they resolve to '
          f'({"census matches this binary" if trusted else "**CENSUS DOES NOT MATCH THIS BINARY — names below are wrong**"}).\n')
    print('| % | samples | symbol |')
    print('|---:|---:|---|')
    for (i, n), d in zip(top, dem):
        print(f'| {100.0 * n / total:.2f} | {n} | `{d[:140]}` |')
    print()

    # Per thread: the same symbols, but which thread ran them. A raster stage
    # hot on VizCompositorThread is a different finding from the same stage
    # hot on the renderer main thread.
    comms = collections.Counter()
    for (comm, i), n in by_comm_sym.items():
        comms[comm] += n
    print('| thread | % of binary | top symbols |')
    print('|---|---:|---|')
    for comm, cn in comms.most_common(8):
        rows = sorted(((n, i) for (c, i), n in by_comm_sym.items() if c == comm),
                      reverse=True)[:4]
        d = demangle([names[i] if i >= 0 else '?' for _, i in rows])
        cells = ', '.join(f'`{x[:60]}` {100.0 * n / cn:.0f}%'
                          for (n, _), x in zip(rows, d))
        print(f'| `{comm}` | {100.0 * cn / total:.1f} | {cells} |')
    print()

    if not trusted or a.annotate <= 0:
        return 0

    # Per-instruction counts inside the top symbols. objdump prints virtual
    # addresses, which is what the samples were shifted to above.
    for (i, n), d in list(zip(top, dem))[:a.annotate]:
        if i < 0:
            continue
        lo, hi = addrs[i], addrs[i] + sizes[i]
        if hi <= lo:
            continue
        try:
            dis = subprocess.run(
                [a.objdump, '-d', '--no-show-raw-insn',
                 f'--start-address={lo:#x}', f'--stop-address={hi:#x}',
                 a.binary],
                capture_output=True, text=True, check=False).stdout
        except OSError as e:
            print(f'_objdump failed: {e}_')
            break
        insns = []
        for line in dis.splitlines():
            m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', line)
            if m:
                insns.append((int(m.group(1), 16), m.group(2).strip()))
        if not insns:
            continue
        # Only the sampled instructions and a few lines around each: a hot
        # Blink function is thousands of instructions, and eight of them per
        # kernel put the whole report past the 1 MiB step-summary cap.
        hot = [k for k, (va, _) in enumerate(insns) if by_addr.get(va)]
        keep = set()
        for k in hot:
            keep.update(range(max(0, k - CONTEXT), min(len(insns), k + CONTEXT + 1)))
        print(f'<details><summary><code>{d[:120]}</code> — {n} samples on '
              f'{len(hot)} of {len(insns)} insns, {hi - lo:#x} bytes</summary>\n')
        print('```')
        last = -1
        for k in sorted(keep):
            if k != last + 1:
                print('      ...')
            va, text = insns[k]
            c = by_addr.get(va, 0)
            mark = f'{c:6d}' if c else '      '
            print(f'{mark}  {va:x}: {text}')
            last = k
        print('```\n</details>\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
