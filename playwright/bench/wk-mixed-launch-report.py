#!/usr/bin/env python3
"""Summarise wk-mixed-launch-probe.cjs output: one row per arm, medians over
every measured launch, each cell `arm vs reference unit (ratio)`.

usage: wk-mixed-launch-report.py <reference-arm> <file.jsonl>...
Lines that are not JSON (`ready <pid>`, Playwright warnings) are skipped by
prefix only; a line that starts with `{` and does not parse is an error.
"""
import json
import statistics
import sys

METRIC_NAMES = ['launch_wall_ms', 'node_cpu_ms', 'node_user_ms', 'node_sys_ms',
                'children_cpu_ms', 'cgroup_cpu_ms']


def load_launch_rows(file_paths):
    rows_by_arm = {}
    for file_path in file_paths:
        with open(file_path) as probe_output:
            for line_text in probe_output:
                if not line_text.startswith('{'):
                    continue
                launch_row = json.loads(line_text)
                rows_by_arm.setdefault(launch_row['arm'], []).append(launch_row)
    return rows_by_arm


def median_of(launch_rows, metric_name):
    return statistics.median(row[metric_name] for row in launch_rows)


def median_alive_ticks(launch_rows):
    comm_names = {name for row in launch_rows for name in row['alive_ticks']}
    return {name: statistics.median(row['alive_ticks'].get(name, 0)
                                    for row in launch_rows)
            for name in comm_names}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    reference_arm = sys.argv[1]
    rows_by_arm = load_launch_rows(sys.argv[2:])
    if reference_arm not in rows_by_arm:
        sys.exit(f'reference arm {reference_arm!r} has no rows; '
                 f'arms seen: {sorted(rows_by_arm)}')
    reference_rows = rows_by_arm[reference_arm]
    print(f'| arm | n | ' + ' | '.join(METRIC_NAMES) + ' |')
    print('|---|---|' + '---|' * len(METRIC_NAMES))
    for arm_name, launch_rows in sorted(rows_by_arm.items()):
        cells = []
        for metric_name in METRIC_NAMES:
            arm_value = median_of(launch_rows, metric_name)
            reference_value = median_of(reference_rows, metric_name)
            ratio_text = (f'{arm_value / reference_value:.2f}'
                          if reference_value else 'ref 0')
            cells.append(f'{arm_value:.1f} vs {reference_value:.1f} ms '
                         f'({ratio_text})')
        print(f'| {arm_name} vs {reference_arm} | {len(launch_rows)} | '
              + ' | '.join(cells) + ' |')
    print()
    print('Median ticks (10 ms) per comm alive just before close, top 8:')
    for arm_name, launch_rows in sorted(rows_by_arm.items()):
        tick_medians = median_alive_ticks(launch_rows)
        top_comms = sorted(tick_medians.items(), key=lambda kv: -kv[1])[:8]
        print(f'- {arm_name}: ' + ', '.join(f'{name}={ticks:g}'
                                            for name, ticks in top_comms))


main()
