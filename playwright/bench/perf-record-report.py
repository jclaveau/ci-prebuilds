#!/usr/bin/env python3
"""Render the two arms' perf profiles side by side, per kernel.

The DSO table is the finding. Both binaries are stripped, so the symbol column
is mostly unresolved, but a shared object is named in the kernel's own mmap
record and needs no symbol table — which is enough to separate "the time is in
zlib" from "the time is in the main binary", and those have different fixes.

Percentages are of the whole system-wide sample, so they are only comparable
between arms once normalised by how much work each arm got through in the
window. `iterations` from the probe carries that, and the per-iteration
milliseconds are printed next to it.

The later passes (instructions, topdown, sched, strace) each have their own
window bracketed by the probe's iteration counter (`<arm>-<kernel>-windows.txt`),
so each is normalised by the iterations IT saw. Our binary's samples are
named when the profile step had the link census (`<arm>-<kernel>-symbols.md`),
and those tables are embedded as written.
"""

import json
import pathlib
import re
import sys

ARMS = ('alpine', 'official')
# Which engine the profile is of, read from the kernels' own metadata (they
# carry `browser` since the webkit/firefox arm); names the headings only.
BROWSER = 'chromium'
ROW = re.compile(r'^\s*(\d+\.\d+)%\s+(\S.*?)\s*$')
EVENT_COUNT = re.compile(r'Event count \(approx\.\): (\d+)')


def cpu_ms_per_iteration(root, arm, kernel, meta):
    """What one iteration cost in CPU-ms, from the profile's own event count.

    Wall time cannot carry this comparison: on a hosted runner both arms'
    screenshot lands on the ~33 ms compositor cadence and reads 1.01x while the
    CPU underneath it is 1.26x. `cpu-clock` counts nanoseconds of CPU across
    every core in the window, so dividing by the iterations that fit in that
    window gives a number a frame boundary cannot flatten.
    """
    dso = root / f'{arm}-{kernel}-dso.txt'
    window = root / f'{arm}-{kernel}-window'
    if not (dso.exists() and window.exists()):
        return None
    m = EVENT_COUNT.search(dso.read_text(errors='replace'))
    if not m or not meta.get('seconds'):
        return None
    iterations = meta['iterations'] / meta['seconds'] \
        * float(window.read_text().strip())
    if iterations <= 0:
        return None
    return int(m.group(1)) / 1e6 / iterations


def read_dso(path):
    """Overhead percent per shared object, from `perf report --sort dso`."""
    out = {}
    if not path.exists():
        return out
    for line in path.read_text(errors='replace').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = ROW.match(line)
        if m:
            out[m.group(2)] = float(m.group(1))
    return out


def windows(root, arm, kernel):
    """{pass: iterations seen} from the bracketing the profile step wrote."""
    f = root / f'{arm}-{kernel}-windows.txt'
    out = {}
    if not f.exists():
        return out
    for line in f.read_text(errors='replace').splitlines():
        p = line.split()
        if len(p) == 4:
            out[p[0]] = max(int(p[3]) - int(p[2]), 0)
    return out


def read_share_table(path):
    """Overhead percent per row label from any `perf report --sort X` file."""
    return read_dso(path)


STAT_ROW = re.compile(
    r'^\s*(<not supported>|<not counted>|[\d,]+(?:\.\d+)?)\s+(?:msec\s+)?'
    r'([A-Za-z][\w.:-]*)')
ELAPSED = re.compile(r'^\s*([\d.]+) seconds time elapsed')


def counter_rates(root, arm, kernel):
    """{event: count per second} from every `perf stat` block the arm wrote.

    The profile step counts in several blocks of different length (the
    hardware list is what a VM refuses, so it is asked for on its own), and
    the dev-box topdown script writes yet another layout. Every block ends
    with its own `seconds time elapsed`, so dividing each event by its block's
    window puts them all on one axis. A `<not supported>` event is dropped
    rather than zeroed: zero would read as "no misses".
    """
    rates, block = {}, {}
    files = [root / f'{arm}-{kernel}-stat.txt',
             root / f'{arm}-{kernel}-topdown.txt']
    if not any(f.exists() for f in files):
        return None
    for f in files:
        if not f.exists():
            continue
        for line in f.read_text(errors='replace').splitlines():
            m = ELAPSED.match(line)
            if m:
                window = float(m.group(1))
                if window > 0:
                    rates.update({e: c / window for e, c in block.items()})
                block = {}
                continue
            m = STAT_ROW.match(line)
            if m and not m.group(1).startswith('<'):
                block[m.group(2)] = float(m.group(1).replace(',', ''))
    meta = root / f'{arm}-{kernel}-kernel.json'
    if meta.exists():
        doc = json.loads(meta.read_text())
        if doc.get('seconds'):
            rates['iter'] = doc['iterations'] / doc['seconds']
    return rates


# (label, numerator event, denominator event, scale) — per-iteration where
# the denominator is `iter`, otherwise per denominator event. The frontend
# split is the one that matters for the campaign: fetch-side misses per
# instruction separate "our code is laid out worse" (orderfile, hugepages)
# from "our code is more instructions" (codegen).
COUNTER_ROWS = (
    ('instructions / iter', 'instructions', 'iter', 1e-6),
    ('cycles / iter', 'cycles', 'iter', 1e-6),
    ('IPC', 'instructions', 'cycles', 1),
    ('L1i miss / kI', 'L1-icache-load-misses', 'instructions', 1e3),
    ('iTLB miss / MI', 'iTLB-load-misses', 'instructions', 1e6),
    ('branch miss %', 'branch-misses', 'branches', 100),
    ('frontend stall / cycle', 'stalled-cycles-frontend', 'cycles', 1),
    ('backend stall / cycle', 'stalled-cycles-backend', 'cycles', 1),
    ('L1d miss / kI', 'L1-dcache-load-misses', 'instructions', 1e3),
    ('LLC miss / MI', 'cache-misses', 'instructions', 1e6),
    ('page faults / iter', 'page-faults', 'iter', 1),
    ('context switches / iter', 'context-switches', 'iter', 1),
    ('task-clock ms / iter', 'task-clock', 'iter', 1),
    ('iTLB loads / MI', 'iTLB-loads', 'instructions', 1e6),
    ('LLC load miss / MI', 'LLC-load-misses', 'instructions', 1e6),
    ('dTLB load miss / MI', 'dTLB-load-misses', 'instructions', 1e6),
)

TOPDOWN_ROW = re.compile(r'#\s+([\d.]+)\s*%\s+(\S+)')


def topdown(root, arm, kernel):
    """{metric: percent} from the topdown metric-group block, if the PMU had one."""
    f = root / f'{arm}-{kernel}-topdown.txt'
    out = {}
    if not f.exists():
        return out
    for line in f.read_text(errors='replace').splitlines():
        m = TOPDOWN_ROW.search(line)
        if m:
            out[m.group(2)] = float(m.group(1))
    return out


def print_topdown_table(kernel, td):
    if not any(td.values()):
        return
    names = sorted(set().union(*(set(v) for v in td.values())))
    print(f'`{kernel}` topdown level 1 (share of pipeline slots):\n')
    print('| metric | alpine | official |')
    print('|---|---:|---:|')
    for n in names:
        cells = ['—' if n not in td[arm] else f'{td[arm][n]:.1f}%' for arm in ARMS]
        print(f'| `{n}` | {cells[0]} | {cells[1]} |')
    print()


SCHED_ROW = re.compile(
    r'^\s*(\S+?)(?::\d+|:\(\d+\))?\s*\|\s*([\d.]+) ms\s*\|\s*(\d+)\s*\|'
    r'\s*avg:\s*([\d.]+) ms\s*\|\s*max:\s*([\d.]+) ms')


def sched(root, arm, kernel):
    """Per thread name: runtime ms, switches, delay-weighted avg, max delay.

    `perf sched latency` prints one row per task (thread), named comm:tid;
    chromium has many threads of one name (raster workers, thread pool), so
    rows fold by comm with the average delay weighted by switch count.
    """
    f = root / f'{arm}-{kernel}-sched.txt'
    out = {}
    if not f.exists():
        return out
    for line in f.read_text(errors='replace').splitlines():
        m = SCHED_ROW.match(line)
        if not m:
            continue
        comm = m.group(1)
        # A row with no name is a task perf could not resolve (a pid from
        # outside the namespace, or one that exited): nothing to fold it into.
        if comm.startswith(':'):
            continue
        rt, n, avg, mx = (float(m.group(2)), int(m.group(3)),
                          float(m.group(4)), float(m.group(5)))
        row = out.setdefault(comm, {'rt': 0.0, 'n': 0, 'delay': 0.0, 'max': 0.0})
        row['rt'] += rt
        row['n'] += n
        row['delay'] += avg * n
        row['max'] = max(row['max'], mx)
    return out


def print_sched_table(kernel, sch, iters):
    if not any(sch.values()) or not all(iters.values()):
        return
    comms = set().union(*(set(v) for v in sch.values()))
    # Rank by the larger arm's runtime, and keep the chromium threads a
    # reader would look for first even when they are cheap.
    def rank(c):
        return -max(sch[a].get(c, {}).get('rt', 0) / iters[a] for a in ARMS)
    rows = sorted(comms, key=rank)[:12]
    print(f'`{kernel}` scheduler, per thread name and iteration '
          '(runtime = on-CPU ms; delay = wakeup→running, avg weighted by '
          'switches):\n')
    print('| thread | run ms alpine | official | switches alpine | official '
          '| avg delay ms alpine | official | max delay ms alpine | official |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    for c in rows:
        cells = []
        for key in ('rt', 'n', 'avgd', 'max'):
            for arm in ARMS:
                r = sch[arm].get(c)
                if not r:
                    cells.append('—')
                elif key == 'rt':
                    cells.append(f'{r["rt"] / iters[arm]:.2f}')
                elif key == 'n':
                    cells.append(f'{r["n"] / iters[arm]:.1f}')
                elif key == 'avgd':
                    cells.append(f'{r["delay"] / r["n"]:.3f}' if r['n'] else '—')
                else:
                    cells.append(f'{r["max"]:.2f}')
        print(f'| `{c}` | ' + ' | '.join(cells) + ' |')
    print()


STRACE_ROW = re.compile(
    r'^\s*([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\d+)\s+(\d+)?\s*([a-z_0-9]+)\s*$')


def strace(root, arm, kernel):
    """{syscall: (wall seconds, calls)} from `strace -c -w`."""
    f = root / f'{arm}-{kernel}-strace.txt'
    out = {}
    if not f.exists():
        return out
    for line in f.read_text(errors='replace').splitlines():
        m = STRACE_ROW.match(line)
        if m and m.group(6) != 'total':
            out[m.group(6)] = (float(m.group(2)), int(m.group(4)))
    return out


def print_strace_table(kernel, st, iters):
    if not any(st.values()) or not all(iters.values()):
        return
    names = set().union(*(set(v) for v in st.values()))
    rows = sorted(names, key=lambda n: -max(
        st[a].get(n, (0, 0))[1] / iters[a] for a in ARMS))[:14]
    print(f'`{kernel}` syscalls per iteration, every {BROWSER} process, wall '
          'time (a futex second is a second a thread WAITED; ptrace slows '
          'the loop, so read the counts and the shares, not the absolute '
          'ms):\n')
    print('| syscall | calls/iter alpine | official | wall ms/iter alpine | official |')
    print('|---|---:|---:|---:|---:|')
    for n in rows:
        cells = []
        for arm in ARMS:
            w, c = st[arm].get(n, (0.0, 0))
            cells.append(f'{c / iters[arm]:.1f}')
        for arm in ARMS:
            w, c = st[arm].get(n, (0.0, 0))
            cells.append(f'{w * 1000 / iters[arm]:.2f}')
        print(f'| `{n}` | ' + ' | '.join(cells) + ' |')
    print()


def print_insn_table(kernel, root, rates, iters):
    """Instruction-weighted share per DSO — the extra instructions, located."""
    share = {arm: read_share_table(root / f'{arm}-{kernel}-insn-dso.txt')
             for arm in ARMS}
    if not any(share.values()):
        for arm in ARMS:
            if (root / f'{arm}-{kernel}-insn-unavailable').exists():
                print(f'- `{arm}` / `{kernel}`: instruction-weighted profile '
                      '**unavailable** (no PMU on this runner)')
        print()
        return
    names = sorted(set().union(*(set(v) for v in share.values())),
                   key=lambda n: -max(share[a].get(n, 0) for a in ARMS))
    # Absolute instructions per iteration by DSO when the counter is there:
    # share × (instructions / iteration) from the stat block.
    absolute = {}
    for arm in ARMS:
        r = rates.get(arm) or {}
        if r.get('instructions') and r.get('iter'):
            absolute[arm] = r['instructions'] / r['iter'] / 1e6
    unit = 'M instructions / iter' if len(absolute) == 2 else 'share of samples'
    print(f'`{kernel}` by shared object, INSTRUCTION-weighted ({unit}). Time '
          'says where the seconds go; this says where the instructions go, '
          'and a DSO higher here than in the time table is code that runs '
          'fast and often — the shape of an inlined check on every call:\n')
    print('| shared object | alpine | official | delta |')
    print('|---|---:|---:|---:|')
    for n in names[:16]:
        vals = []
        for arm in ARMS:
            sh = share[arm].get(n)
            if sh is None:
                vals.append(None)
            elif arm in absolute and len(absolute) == 2:
                vals.append(sh / 100 * absolute[arm])
            else:
                vals.append(sh)
        cells = ['—' if v is None else
                 (f'{v:.1f}' if len(absolute) == 2 else f'{v:.2f}%')
                 for v in vals]
        d = '—'
        if None not in vals:
            d = f'{vals[0] - vals[1]:+.1f}' if len(absolute) == 2 \
                else f'{vals[0] - vals[1]:+.2f} pt'
        print(f'| `{n}` | {cells[0]} | {cells[1]} | {d} |')
    print()


def print_symbols(kernel, root):
    """Our named hot list, embedded as the profile step wrote it."""
    for suffix, what in (('symbols', 'time-weighted'),
                         ('insn-symbols', 'instruction-weighted')):
        f = root / f'alpine-{kernel}-{suffix}.md'
        if not f.exists():
            continue
        # The tables only: the per-instruction listings that follow them are
        # for the artifact, the step summary stops accepting at 1 MiB.
        body = f.read_text(errors='replace').split('<details>', 1)[0]
        print(f'<details><summary>`alpine` / `{kernel}` named hot symbols, '
              f'{what} (from the link census or the unstripped twin; '
              f'annotated listings in the artifact)</summary>\n')
        print(body)
        print('</details>\n')



def print_counter_table(kernel, rates):
    """The two arms' counters per iteration and per instruction, with the ratio.

    Per iteration rather than per window: the arms get through different
    numbers of iterations in the same seconds, and the kernel JSON carries
    each arm's own rate. Per instruction for the miss rows, which is the
    normalisation the frontend-fetch finding was read in.
    """
    if any(r is None for r in rates.values()):
        return
    rows = []
    for label, num, den, scale in COUNTER_ROWS:
        vals = {}
        for arm, r in rates.items():
            d = r.get('iter') if den == 'iter' else r.get(den)
            if num not in r or not d:
                vals[arm] = None
            else:
                vals[arm] = r[num] / d * scale
        if all(v is None for v in vals.values()):
            continue
        rows.append((label, vals))
    if not rows:
        return
    print(f'`{kernel}` per iteration / per instruction '
          '(M = millions, kI/MI = per thousand/million instructions):\n')
    print('| counter | alpine | official | ratio |')
    print('|---|---|---|---|')
    for label, vals in rows:
        a, o = vals.get('alpine'), vals.get('official')
        cells = ['—' if v is None else f'{v:.3g}' for v in (a, o)]
        ratio = '—' if not (a and o) else f'**{a / o:.2f}x**'
        print(f'| {label} | {cells[0]} | {cells[1]} | {ratio} |')
    print()


def main(root):
    root = pathlib.Path(root)
    kernels = sorted({
        p.name.split('-', 1)[1].rsplit('-kernel.json', 1)[0]
        for p in root.glob('*-kernel.json')
    })
    if not kernels:
        print('No kernel completed — read the per-arm logs in the artifact.')
        return 0

    global BROWSER
    for p in root.glob('*-kernel.json'):
        BROWSER = json.loads(p.read_text()).get('browser', BROWSER)
        break
    print(f'## {BROWSER} perf record — where the CPU time went\n')

    versions = {}
    for kernel in kernels:
        meta = {}
        for arm in ARMS:
            f = root / f'{arm}-{kernel}-kernel.json'
            if f.exists():
                meta[arm] = json.loads(f.read_text())
                # The shipped artifact's own answer beside Playwright's: for
                # webkit browser_version is a playwright-core constant and
                # only the so-name can tell two builds apart.
                v = meta[arm].get('browser_version', '?')
                if meta[arm].get('binary_version'):
                    v = f"{v} / {meta[arm]['binary_version']}"
                versions.setdefault(arm, set()).add(v)

        print(f'### `{kernel}`\n')
        cpu = {arm: None for arm in ARMS}
        if len(meta) == len(ARMS):
            a, o = meta['alpine'], meta['official']
            cpu = {arm: cpu_ms_per_iteration(root, arm, kernel, meta[arm])
                   for arm in ARMS}
            wall = (a['median_ms'] / o['median_ms']) if o['median_ms'] else 0
            cpu_ratio = None
            if cpu['alpine'] and cpu['official']:
                cpu_ratio = cpu['alpine'] / cpu['official']
            print('| arm | iterations | median ms | wall | CPU-ms/iter | CPU |'
                  ' output tag |')
            print('|---|---|---|---|---|---|---|')
            for arm, m in (('alpine', a), ('official', o)):
                c = cpu[arm]
                mine = arm == 'alpine'
                print(f'| {arm} | {m["iterations"]} | {m["median_ms"]:.2f} | '
                      + (f'**{wall:.2f}x**' if mine else '1.00x') + ' | '
                      + ('—' if c is None else f'{c:.1f}') + ' | '
                      + ('1.00x' if not mine else
                         '—' if cpu_ratio is None else f'**{cpu_ratio:.2f}x**')
                      + f' | `{m["tag"]}` |')
            if abs(wall - 1) < 0.03 and cpu_ratio and abs(cpu_ratio - 1) > 0.1:
                print('\n> Wall time is flat while CPU is not: this kernel is '
                      'sitting on the compositor cadence, so its wall column '
                      'is a frame boundary rather than a measurement. Read the '
                      'CPU column.')
            if a['tag'] != o['tag'] and a.get('bytes_comparable', True):
                print('\n> The two arms produced DIFFERENT output on a kernel '
                      'whose bytes are supposed to match. For an encoder that '
                      'is a real difference worth its own look; for a layout '
                      'kernel it means the arms were not laying out the same '
                      'boxes and the ratios above are void.')
            print()

        dso = {arm: read_dso(root / f'{arm}-{kernel}-dso.txt') for arm in ARMS}
        names = sorted(
            set(dso['alpine']) | set(dso['official']),
            key=lambda n: -max(dso['alpine'].get(n, 0),
                               dso['official'].get(n, 0)),
        )
        if not names:
            print('_perf produced no samples for this kernel._\n')
            continue

        print('CPU-ms per iteration, by shared object. A raw share would not '
              'be comparable between the arms: they get through different '
              'numbers of iterations in the same window, so each share is '
              'weighted by that arm\'s own cost per iteration.\n')
        print('| shared object | alpine | official | delta |')
        print('|---|---|---|---|')
        for n in names[:22]:
            cells, vals = [], {}
            for arm in ARMS:
                share, c = dso[arm].get(n), cpu[arm]
                if c is None:
                    vals[arm] = None
                    cells.append('—' if share is None else f'{share:.2f}%')
                else:
                    vals[arm] = (share or 0.0) / 100 * c
                    cells.append(f'{vals[arm]:.2f} ms')
            if vals['alpine'] is None or vals['official'] is None:
                cells.append('—')
            else:
                cells.append(f"{vals['alpine'] - vals['official']:+.2f} ms")
            print(f'| `{n}` | ' + ' | '.join(cells) + ' |')
        print()

    print('### Version parity\n')
    for arm in ARMS:
        seen = sorted(versions.get(arm, {'(no run completed)'}))
        print(f'- **{arm}**: {", ".join(seen)}')
    alpine_v = versions.get('alpine', set())
    official_v = versions.get('official', set())
    if alpine_v and official_v and alpine_v != official_v:
        print(f'\n> The arms are on DIFFERENT {BROWSER} versions. Everything '
              'above is a comparison of two browsers, not of two builds.')
    print()

    print('### Counters\n')
    print('Hardware counters are frequently unavailable on a hosted runner '
          '(the PMU is not virtualised through), which is why the record step '
          'samples `cpu-clock` rather than `cycles`. Full `perf stat` output '
          'is in the artifact.\n')
    for kernel in kernels:
        rates = {arm: counter_rates(root, arm, kernel) for arm in ARMS}
        for arm in ARMS:
            if rates[arm] is None:
                continue
            hw = 'instructions' in rates[arm]
            print(f'- `{arm}` / `{kernel}`: hardware counters '
                  f'{"available" if hw else "**unavailable**"}')
        print()
        print_counter_table(kernel, rates)
        print_topdown_table(kernel, {arm: topdown(root, arm, kernel) for arm in ARMS})
        win = {arm: windows(root, arm, kernel) for arm in ARMS}
        print_insn_table(kernel, root, rates, win)
        print_symbols(kernel, root)

    print('### Threads and syscalls\n')
    print('On-CPU profiles cannot see a thread that is waiting. The scheduler '
          'table is wake-up latency and switches per thread; the syscall '
          'table is the kernel boundary per iteration, wall-clock.\n')
    for kernel in kernels:
        win = {arm: windows(root, arm, kernel) for arm in ARMS}
        print_sched_table(kernel, {arm: sched(root, arm, kernel) for arm in ARMS},
                          {arm: win[arm].get('sched', 0) for arm in ARMS})
        print_strace_table(kernel, {arm: strace(root, arm, kernel) for arm in ARMS},
                           {arm: win[arm].get('strace', 0) for arm in ARMS})
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'perf-out'))
