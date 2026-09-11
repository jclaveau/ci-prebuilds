#!/usr/bin/env python3
"""Turn the counting-memset preload's per-process lines into a size histogram.

The shim appends a cumulative line per process every 2^17 calls and once
more at exit; the last line for a pid is the one that counts:

    pid=42 comm=chrome calls=8040 bytes=804000 hist=40:0,280:1120,...

`hist` is twelve `calls:bytes` pairs against the bucket edges below, and the
distribution is the whole point of the arm. perf already said `memset` is the
hottest symbol in our chromium; what it could not say is whether those are a
few large fills (bandwidth, and a wider store would help) or millions of tiny
ones (call overhead, and a wider store would not). Read the `% calls` column
first — if it collapses below 32 bytes, no AVX2 memset was ever going to move
the layout row, which is what the retracted fast-string shim measured.

Two things this report cannot tell you, both by construction:

  - It counts only INTERPOSABLE calls. musl resolves its own internal memsets
    without going through the dynamic symbol table, so anything libc does to
    itself is invisible here. That absence is the other half of the finding and
    it is read off the perf DSO report, not off this file: if `memset` in
    ld-musl stays hot while these counts are large, the two sets are disjoint.
  - A process killed before its first tick reports nothing, and one killed
    between ticks under-reports by up to 2^17 calls. Chromium SIGKILLs its
    renderers on close, which is why the ticks exist: the renderer is where
    layout runs, and run 34619723608 heard from the browser process only.

Files are `memset-count-<target>-<kernel>.txt`, one per side, and the report
puts the two sides of a kernel beside each other: the same shim over glibc
gives the control the same histogram, and a call count that differs between
the two binaries under one kernel is a code-path divergence, not a libc one.

usage: memset-count-report.py <perf-out-dir>
"""
import pathlib
import sys

# Must match BUCKET_MAX in memset-count-preload.c.
EDGES = [1, 8, 16, 32, 64, 128, 256, 1024, 4096, 65536, 1048576, None]


def bucket_labels():
    labels = ['0 B']
    low = 1
    for edge in EDGES[1:]:
        if edge is None:
            labels.append(f'{low} B+')
        else:
            labels.append(f'{low}-{edge - 1} B')
            low = edge
    return labels


def parse(path):
    """(latest row per pid, load announcements). The shim writes `loaded pid=
    comm=` at exec and cumulative counts every tick and at exit, so a pid's
    last line supersedes its earlier ones. Renderers are forked from the
    zygote without an exec and never announce, so they can appear in the rows
    without appearing in the announcements."""
    rows = {}
    loaded = []
    for line in path.read_text().splitlines():
        fields = dict(f.split('=', 1) for f in line.split() if '=' in f)
        if line.startswith('loaded '):
            loaded.append(fields.get('comm', '?'))
            continue
        if 'hist' not in fields:
            continue
        pairs = [p.split(':') for p in fields['hist'].split(',')]
        rows[fields.get('pid', '?')] = {
            'pid': fields.get('pid', '?'),
            'comm': fields.get('comm', '?'),
            'calls': int(fields.get('calls', 0)),
            'bytes': int(fields.get('bytes', 0)),
            'hist': [(int(c), int(b)) for c, b in pairs],
        }
    return list(rows.values()), loaded


SIDES = ('alpine', 'official')


def histogram(rows):
    """Per-bucket (calls, bytes) over the chromium rows only. On the official
    side the preload rides the environment and node counts itself too; that
    is tooling, and the comparison is browser against browser."""
    browser = [r for r in rows if r['comm'].startswith('chrome')]
    calls = [sum(r['hist'][i][0] for r in browser) for i in range(len(EDGES))]
    nbytes = [sum(r['hist'][i][1] for r in browser) for i in range(len(EDGES))]
    return calls, nbytes


def render(kernel, sides):
    """sides: {target: (rows, loaded)} for one kernel, either side optional."""
    print(f'#### `{kernel}`\n')
    hist = {}
    for target in SIDES:
        if target not in sides:
            print(f'- {target}: no file — the side did not count')
            continue
        rows, loaded = sides[target]
        chromium = sum(1 for c in loaded if c.startswith('chrome'))
        print(f'- {target}: {len(loaded)} processes loaded the shim '
              f'({chromium} chromium), {len(rows)} reported')
        if not chromium:
            print(f'  **no chromium process loaded the shim on the {target} '
                  'side — its counts are node and the tooling. Void.**')
            continue
        hist[target] = histogram(rows)
    print()
    if not hist:
        return

    for target, (calls, nbytes) in hist.items():
        total = sum(calls)
        if not total:
            print(f'{target}: no interposed memset calls at all.\n')
            continue
        print(f'{target}: {total:,} calls, {sum(nbytes):,} bytes, '
              f'mean {sum(nbytes) / total:.0f} B per call.')
    if len(hist) == 2:
        a, o = (sum(hist[t][0]) for t in SIDES)
        ab, ob = (sum(hist[t][1]) for t in SIDES)
        if a and o:
            print(f'alpine/official: **{a / o:.2f}x calls, {ab / ob:.2f}x '
                  'bytes** — the same kernel, so a ratio away from 1.00 is '
                  'a code-path divergence, not a libc one.')
    print()

    # One row per bucket with both sides beside each other: the question is
    # whether the two binaries fill the same sizes, and two separate tables
    # would leave that to the reader.
    head = '| size |'
    rule = '|---|'
    for target in hist:
        head += f' {target} calls | % | {target} bytes | % |'
        rule += '---|---|---|---|'
    print(head)
    print(rule)
    for i, label in enumerate(bucket_labels()):
        if not any(hist[t][0][i] for t in hist):
            continue
        line = f'| {label} |'
        for target, (calls, nbytes) in hist.items():
            tc, tb = max(sum(calls), 1), max(sum(nbytes), 1)
            line += (f' {calls[i]:,} | {100 * calls[i] / tc:.1f}% '
                     f'| {nbytes[i]:,} | {100 * nbytes[i] / tb:.1f}% |')
        print(line)
    print()

    # Per pid, not per comm: every chromium process is `chrome-headless`, and
    # the row that dwarfs the others is the renderer.
    print('| side | pid | process | calls | bytes |')
    print('|---|---|---|---|---|')
    for target in hist:
        rows = sides[target][0]
        for row in sorted(rows, key=lambda r: -r['calls']):
            if not row['calls']:
                continue
            print(f"| {target} | {row['pid']} | `{row['comm']}` "
                  f"| {row['calls']:,} | {row['bytes']:,} |")
    print()


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'perf-out')
    files = sorted(out.glob('memset-count-*.txt'))
    if not files:
        print('_No memset-count file — the arm did not run._')
        return
    print('### memset call sizes (counting preload, both arms)\n')
    # Files are memset-count-<target>-<kernel>.txt; group the two targets of
    # one kernel so the report can put them side by side.
    kernels = {}
    for path in files:
        target, kernel = path.stem[len('memset-count-'):].split('-', 1)
        kernels.setdefault(kernel, {})[target] = parse(path)
    for kernel, sides in kernels.items():
        render(kernel, sides)


if __name__ == '__main__':
    main()
