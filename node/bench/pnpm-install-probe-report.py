#!/usr/bin/env python3
"""pnpm-install-probe-report.py <out-dir>: markdown tables from pnpm-install-probe.sh output.

Per arm: median cgroup user / sys CPU-s and page faults of the offline install,
each against the first arm (the ubuntu glibc binary of the old pnpm); then the
strace -f -c counts of the syscalls the musl allocator moves.
"""
import re
import statistics
import sys
from pathlib import Path

out_dir = Path(sys.argv[1])
host_text = (out_dir / 'host.txt').read_text()
print('### pnpm install probe\n')
print('```\n' + host_text.strip() + '\n```\n')

counter_names = ('user_usec', 'system_usec', 'pgfault')
arm_samples = {}
for line in (out_dir / 'runs.txt').read_text().splitlines():
    if not line.startswith('round='):
        continue
    arm_name = re.search(r'arm=(\S+)', line).group(1)
    before_text, after_text = line.split(' before: ')[1].split(' after: ')
    before_values = dict(pair.split('=') for pair in before_text.split())
    after_values = dict(pair.split('=') for pair in after_text.split())
    deltas = {name: int(after_values[name]) - int(before_values[name]) for name in counter_names}
    arm_samples.setdefault(arm_name, []).append(deltas)

if not arm_samples:
    sys.exit(f'no round= lines in {out_dir / "runs.txt"}')

# The warm lines list the arms in ARM_SPECS order; the first is the reference.
spec_order = re.findall(r'^warm (\S+) ', host_text, re.M)
arm_samples = {arm: arm_samples[arm] for arm in spec_order if arm in arm_samples}
reference_arm = next(iter(arm_samples))


def median_of(arm_name, counter_name):
    return statistics.median(sample[counter_name] for sample in arm_samples[arm_name])


def cell(arm_name, counter_name, scale, unit):
    value = median_of(arm_name, counter_name) / scale
    reference = median_of(reference_arm, counter_name) / scale
    ratio = value / reference if reference else float('nan')
    return f'{value:.2f} vs {reference:.2f} {unit} ({ratio:.2f}x)'


print(f'Medians over {len(arm_samples[reference_arm])} interleaved rounds; '
      f'each cell is `arm vs {reference_arm}`.\n')
print('| arm | n | user | sys | page faults (k) |')
print('|---|---|---|---|---|')
for arm_name, samples in arm_samples.items():
    print(f'| {arm_name} | {len(samples)} | {cell(arm_name, "user_usec", 1e6, "s")} '
          f'| {cell(arm_name, "system_usec", 1e6, "s")} | {cell(arm_name, "pgfault", 1e3, "k")} |')

watched_syscalls = ('futex', 'mmap', 'munmap', 'madvise', 'brk', 'mprotect', 'sched_yield',
                    'linkat', 'statx', 'stat', 'openat', 'open')
strace_counts = {}
for arm_name in arm_samples:
    strace_file = out_dir / f'strace-{arm_name}.txt'
    if not strace_file.exists():
        continue
    calls_by_syscall = {}
    for line in strace_file.read_text().splitlines():
        fields = line.split()
        # rows: % time, seconds, usecs/call, calls, [errors], syscall
        if len(fields) >= 5 and re.match(r'^[\d.]+$', fields[0]) and fields[-1].isidentifier():
            calls_by_syscall[fields[-1]] = int(fields[3])
    strace_counts[arm_name] = calls_by_syscall

if strace_counts:
    print('\nstrace -f -c calls (one pass per arm):\n')
    print('| syscall | ' + ' | '.join(strace_counts) + ' |')
    print('|---|' + '---|' * len(strace_counts))
    for syscall_name in watched_syscalls:
        row_values = [str(strace_counts[arm].get(syscall_name, 0)) for arm in strace_counts]
        print(f'| {syscall_name} | ' + ' | '.join(row_values) + ' |')

perf_files = sorted(out_dir.glob('perf-*.txt'))
for perf_file in perf_files:
    print(f'\n`{perf_file.name}`:\n```\n{perf_file.read_text().strip()}\n```')
