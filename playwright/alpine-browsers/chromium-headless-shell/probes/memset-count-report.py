#!/usr/bin/env python3
"""Turn the counting-memset preload's per-process lines into a size histogram.

The shim appends one line per process that exits under it:

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
  - Processes killed rather than exited never run the destructor and never
    report. Chromium's renderers usually exit cleanly on close, but a missing
    comm is a missing process, not a process that filled no memory.

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
    rows = []
    for line in path.read_text().splitlines():
        fields = dict(f.split('=', 1) for f in line.split() if '=' in f)
        if 'hist' not in fields:
            continue
        pairs = [p.split(':') for p in fields['hist'].split(',')]
        rows.append({
            'comm': fields.get('comm', '?'),
            'calls': int(fields.get('calls', 0)),
            'bytes': int(fields.get('bytes', 0)),
            'hist': [(int(c), int(b)) for c, b in pairs],
        })
    return rows


def render(kernel, rows):
    total_calls = sum(r['calls'] for r in rows)
    total_bytes = sum(r['bytes'] for r in rows)
    print(f'#### `{kernel}` — {len(rows)} processes reported\n')
    if not total_calls:
        print('No interposed memset calls at all. Either the shim was not '
              'loaded, or every call musl serves is internal to musl.\n')
        return

    mean = total_bytes / total_calls
    print(f'{total_calls:,} calls, {total_bytes:,} bytes, mean {mean:.0f} B '
          'per call.\n')

    print('| size | calls | % calls | bytes | % bytes |')
    print('|---|---|---|---|---|')
    for i, label in enumerate(bucket_labels()):
        calls = sum(r['hist'][i][0] for r in rows)
        nbytes = sum(r['hist'][i][1] for r in rows)
        if not calls:
            continue
        print(f'| {label} | {calls:,} | {100 * calls / total_calls:.1f}% '
              f'| {nbytes:,} | {100 * nbytes / max(total_bytes, 1):.1f}% |')
    print()

    print('| process | calls | bytes |')
    print('|---|---|---|')
    by_comm = {}
    for row in rows:
        got = by_comm.setdefault(row['comm'], [0, 0])
        got[0] += row['calls']
        got[1] += row['bytes']
    for comm, (calls, nbytes) in sorted(
            by_comm.items(), key=lambda kv: -kv[1][0]):
        print(f'| `{comm}` | {calls:,} | {nbytes:,} |')
    print()


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'perf-out')
    files = sorted(out.glob('memset-count-*.txt'))
    if not files:
        print('_No memset-count file — the arm did not run._')
        return
    print('### memset call sizes (alpine arm, counting preload)\n')
    for path in files:
        render(path.stem[len('memset-count-'):], parse(path))


if __name__ == '__main__':
    main()
