#!/usr/bin/env python3
"""Print the top self-time functions of a V8 .cpuprofile (node --cpu-prof).

usage: cpuprofile-top.py <file.cpuprofile> [top_count]
"""
import json
import sys
from collections import Counter

if len(sys.argv) < 2:
    sys.exit(__doc__)
with open(sys.argv[1]) as profile_file:
    cpu_profile = json.load(profile_file)
top_count = int(sys.argv[2]) if len(sys.argv) > 2 else 25

frame_by_node_id = {}
for profile_node in cpu_profile['nodes']:
    call_frame = profile_node['callFrame']
    script_name = call_frame['url'].rsplit('/', 1)[-1] or '(native)'
    frame_by_node_id[profile_node['id']] = (
        f"{call_frame['functionName'] or '(anonymous)'} "
        f"{script_name}:{call_frame['lineNumber'] + 1}")

self_us_by_frame = Counter()
for sample_node_id, delta_us in zip(cpu_profile['samples'],
                                    cpu_profile['timeDeltas']):
    self_us_by_frame[frame_by_node_id[sample_node_id]] += delta_us

total_us = sum(self_us_by_frame.values())
print(f'total sampled {total_us / 1000:.1f} ms')
for frame_name, self_us in self_us_by_frame.most_common(top_count):
    print(f'{self_us / 1000:9.1f} ms {100 * self_us / total_us:5.1f}%  '
          f'{frame_name}')
