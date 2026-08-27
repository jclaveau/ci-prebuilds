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
"""

import json
import pathlib
import re
import sys

ARMS = ('alpine', 'official')
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


def main(root):
    root = pathlib.Path(root)
    kernels = sorted({
        p.name.split('-', 1)[1].rsplit('-kernel.json', 1)[0]
        for p in root.glob('*-kernel.json')
    })
    if not kernels:
        print('No kernel completed — read the per-arm logs in the artifact.')
        return 0

    print('## chromium perf record — where the CPU time went\n')

    versions = {}
    for kernel in kernels:
        meta = {}
        for arm in ARMS:
            f = root / f'{arm}-{kernel}-kernel.json'
            if f.exists():
                meta[arm] = json.loads(f.read_text())
                versions.setdefault(arm, set()).add(
                    meta[arm].get('browser_version', '?'))

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
        print('\n> The arms are on DIFFERENT chromium versions. Everything '
              'above is a comparison of two browsers, not of two builds.')
    print()

    print('### Counters\n')
    print('Hardware counters are frequently unavailable on a hosted runner '
          '(the PMU is not virtualised through), which is why the record step '
          'samples `cpu-clock` rather than `cycles`. Full `perf stat` output '
          'is in the artifact.\n')
    for kernel in kernels:
        for arm in ARMS:
            f = root / f'{arm}-{kernel}-stat.txt'
            if not f.exists():
                continue
            text = f.read_text(errors='replace')
            supported = 'not supported' not in text
            print(f'- `{arm}` / `{kernel}`: hardware counters '
                  f'{"available" if supported else "**unavailable**"}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'perf-out'))
