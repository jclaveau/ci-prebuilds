"""Tabulates run-arms output: median CPU-ms per arm and input, against a reference.

usage: report.py <out-dir>   (reads cpu.txt, heads.txt, times/<input>/<arm>-<round>.txt)

An arm built with PGO is read against pgo_off, another headers_* arm against
headers, every other arm against pad0, so each ratio is what the arm's change
does in its build shape.
"""
import pathlib
import statistics
import sys

out_dir = pathlib.Path(sys.argv[1])
cpu_model = (out_dir / 'cpu.txt').read_text().strip()
head_rows = {}
for row in (out_dir / 'heads.txt').read_text().splitlines():
    arm_name, _, summary = row.partition(': ')
    head_rows[arm_name] = summary
input_dirs = sorted(path for path in (out_dir / 'times').iterdir() if path.is_dir())
if not input_dirs:
    sys.exit(f'no input directory under {str(out_dir / "times")!r}')

print(f'### zlib arms, {cpu_model}\n')
for input_dir in input_dirs:
    arm_times = {}
    for time_file in sorted(input_dir.glob('*.txt')):
        arm_name = time_file.stem.rsplit('-', 1)[0]
        for row in time_file.read_text().split('\n'):
            if row.strip():
                deflate_ms, inflate_ms, packed_size = row.split()
                arm_times.setdefault(arm_name, []).append((float(deflate_ms), float(inflate_ms), int(packed_size)))
    missing_arms = sorted(set(head_rows) - set(arm_times))
    if missing_arms:
        sys.exit(f'{input_dir.name!r}: no timings for arm(s): {missing_arms!r}')
    packed_sizes = {sample[2] for samples in arm_times.values() for sample in samples}
    if len(packed_sizes) != 1:
        sys.exit(f'{input_dir.name!r}: arms compressed to different sizes: {sorted(packed_sizes)!r}')

    def medians(arm_name):
        samples = arm_times[arm_name]
        return (statistics.median(sample[0] for sample in samples),
                statistics.median(sample[1] for sample in samples))

    print(f'#### input {input_dir.name}\n')
    print(f'{packed_sizes.pop():,} compressed bytes in every arm. Median CPU-ms.\n')
    print('| arm | deflate | inflate | n | deflate_slow placement |')
    print('| --- | --- | --- | --- | --- |')
    for arm_name in sorted(arm_times):
        if 'pgo' in arm_name:
            reference_arm = 'pgo_off'
        elif arm_name.startswith('headers_'):
            reference_arm = 'headers'
        else:
            reference_arm = 'pad0'
        deflate_median, inflate_median = medians(arm_name)
        reference_deflate, reference_inflate = medians(reference_arm)
        print(f'| {arm_name} '
              f'| {deflate_median:.1f} vs {reference_deflate:.1f} ms {reference_arm} ({deflate_median / reference_deflate:.3f}x) '
              f'| {inflate_median:.1f} vs {reference_inflate:.1f} ms {reference_arm} ({inflate_median / reference_inflate:.3f}x) '
              f'| {len(arm_times[arm_name])} | {head_rows[arm_name]} |')
    print()
