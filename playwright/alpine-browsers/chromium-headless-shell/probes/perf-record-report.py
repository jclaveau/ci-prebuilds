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
        if len(meta) == len(ARMS):
            a, o = meta['alpine'], meta['official']
            ratio = (a['median_ms'] / o['median_ms']) if o['median_ms'] else 0
            print('| arm | iterations | median ms | ratio | output tag |')
            print('|---|---|---|---|---|')
            print(f"| alpine | {a['iterations']} | {a['median_ms']:.2f} | "
                  f"**{ratio:.2f}x** | `{a['tag']}` |")
            print(f"| official | {o['iterations']} | {o['median_ms']:.2f} | "
                  f"1.00x | `{o['tag']}` |")
            if a['tag'] != o['tag']:
                print('\n> The two arms produced DIFFERENT output. For an '
                      'encoder kernel that is a real difference worth its own '
                      'look; for a layout kernel it means the arms were not '
                      'laying out the same boxes and the ratio above is void.')
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

        print('Share of system-wide CPU samples, by shared object:\n')
        print('| shared object | alpine | official |')
        print('|---|---|---|')
        for n in names[:22]:
            a = dso['alpine'].get(n)
            o = dso['official'].get(n)
            print(f'| `{n}` | {"—" if a is None else f"{a:.2f}%"} '
                  f'| {"—" if o is None else f"{o:.2f}%"} |')
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
