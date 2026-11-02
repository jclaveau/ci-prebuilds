"""Tabulates run-arms output: median CPU-ms per arm, each against pad0.

usage: report.py <out-dir>   (reads cpu.txt, heads.txt, times/<arm>-<round>.txt)
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
arm_times = {}
for time_file in sorted((out_dir / 'times').glob('*.txt')):
    arm_name = time_file.stem.rsplit('-', 1)[0]
    for row in time_file.read_text().split('\n'):
        if row.strip():
            deflate_ms, inflate_ms, packed_size = row.split()
            arm_times.setdefault(arm_name, []).append((float(deflate_ms), float(inflate_ms), int(packed_size)))
missing_arms = sorted(set(head_rows) - set(arm_times))
if missing_arms:
    sys.exit(f'no timings for arm(s): {", ".join(missing_arms)}')
packed_sizes = {sample[2] for samples in arm_times.values() for sample in samples}
if len(packed_sizes) != 1:
    sys.exit(f'arms compressed to different sizes: {sorted(packed_sizes)}')

reference_arm = 'pad0'
reference_deflate = statistics.median(sample[0] for sample in arm_times[reference_arm])
reference_inflate = statistics.median(sample[1] for sample in arm_times[reference_arm])
print(f'### zlib loop placement, {cpu_model}\n')
print(f'{packed_sizes.pop():,} compressed bytes in every arm. Median CPU-ms, each arm vs {reference_arm}.\n')
print('| arm | deflate | inflate | n | deflate_slow placement |')
print('| --- | --- | --- | --- | --- |')
for arm_name in sorted(arm_times):
    samples = arm_times[arm_name]
    deflate_median = statistics.median(sample[0] for sample in samples)
    inflate_median = statistics.median(sample[1] for sample in samples)
    print(f'| {arm_name} '
          f'| {deflate_median:.1f} vs {reference_deflate:.1f} ms ({deflate_median / reference_deflate:.3f}x) '
          f'| {inflate_median:.1f} vs {reference_inflate:.1f} ms ({inflate_median / reference_inflate:.3f}x) '
          f'| {len(samples)} | {head_rows[arm_name]} |')
