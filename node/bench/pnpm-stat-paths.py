#!/usr/bin/env python3
"""pnpm-stat-paths.py <strace -f -e trace=%stat,%lstat,%fstat log>

Summarises which paths an install stats: calls per syscall and flag set, calls
per path area, how many paths are stat'ed once, twice, more, and the paths
stat'ed most. A path is the string argument, resolved against nothing: an
fd-relative call (`""` with AT_EMPTY_PATH) is counted as `<fd>`.
"""
import collections
import re
import sys

call_pattern = re.compile(r'^(?:\[pid\s+)?\d+\]?\s+(\w+)\((.*)$')
path_pattern = re.compile(r'"((?:[^"\\]|\\.)*)"')
flag_pattern = re.compile(r'\b(AT_[A-Z_]+|STATX_[A-Z_]+)')

calls_by_syscall = collections.Counter()
calls_by_flags = collections.Counter()
calls_by_area = collections.Counter()
calls_by_path = collections.Counter()
failed_calls = collections.Counter()
line_count = 0
for raw_line in open(sys.argv[1], errors='replace'):
    call_match = call_pattern.match(raw_line)
    if not call_match:
        continue
    line_count += 1
    syscall_name, call_rest = call_match.groups()
    calls_by_syscall[syscall_name] += 1
    flag_names = sorted(set(flag_pattern.findall(re.sub(r'\{[^}]*\}', '', call_rest))))
    calls_by_flags[f'{syscall_name} {"|".join(flag_names) or "-"}'] += 1
    path_match = path_pattern.search(call_rest)
    path_text = path_match.group(1) if path_match and path_match.group(1) else '<fd>'
    calls_by_path[path_text] += 1
    if path_text == '<fd>':
        area_name = '<fd>'
    elif '/node_modules/' in path_text or path_text.endswith('/node_modules'):
        area_name = 'store' if path_text.startswith('/w/store') else 'node_modules'
    elif path_text.startswith('/w/store'):
        area_name = 'store'
    elif path_text.startswith('/w/fx'):
        area_name = 'workspace (not node_modules)'
    else:
        area_name = 'other'
    calls_by_area[area_name] += 1
    if re.search(r'= -1 (E\w+)', raw_line):
        failed_calls[f'{syscall_name} {re.search(r"= -1 (E\w+)", raw_line).group(1)}'] += 1

if not line_count:
    raise SystemExit(f'{sys.argv[1]}: no stat-family call parsed')

print(f'calls: {line_count}  distinct paths: {len(calls_by_path)}')
for title, counter in (('by syscall', calls_by_syscall), ('by syscall + flags', calls_by_flags),
                       ('by area', calls_by_area), ('failed', failed_calls)):
    print(f'\n{title}:')
    for key_text, call_count in counter.most_common(12):
        print(f'  {call_count:>8}  {key_text}')
times_histogram = collections.Counter(min(call_count, 5) for call_count in calls_by_path.values())
print('\npaths by times stat\'ed (5 = 5 or more):')
for times_count in sorted(times_histogram):
    print(f'  {times_count}x  {times_histogram[times_count]} paths')
print('\nmost-stat\'ed paths:')
for path_text, call_count in calls_by_path.most_common(25):
    print(f'  {call_count:>6}  {path_text}')
