#!/usr/bin/env python3
"""Symbolize a crash-<pid>.txt written by crash-report.c.

    pgo-symbolize-crash.py <llvm-symbolizer> <crash-report>

Prints the signal line, the string-looking registers and stack words (where a
RELEASE_ASSERT's __FILE__ and function name usually sit), then rip and every
stack word that lands in a mapped file's executable range, symbolized against
that file. Must run before Phase 0 deletes the instrumented build tree, since
the maps point into it.
"""
import json
import subprocess
import sys


def read_report(report_path):
    words, mappings, header = [], [], ''
    in_maps = False
    with open(report_path, errors='replace') as report:
        for line in report:
            line = line.rstrip('\n')
            if line == '--- maps':
                in_maps = True
            elif in_maps:
                fields = line.split(None, 5)
                if len(fields) < 6:
                    continue
                start_text, end_text = fields[0].split('-')
                mappings.append({
                    'start': int(start_text, 16), 'end': int(end_text, 16),
                    'perms': fields[1], 'offset': int(fields[2], 16),
                    'path': fields[5],
                })
            elif line.startswith('signal '):
                header = line
            elif line.startswith(('reg ', 'stack ')):
                label, value_text = line.split(' str=')[0].rsplit(' ', 1)
                words.append((label, int(value_text, 16), line))
    return header, words, mappings


def load_bases(mappings):
    # A library's load base is its lowest mapping minus that mapping's file
    # offset, which is what turns a runtime address into the address
    # llvm-symbolizer expects for a PIE or shared object.
    bases = {}
    for mapping in mappings:
        if not mapping['path'].startswith('/'):
            continue
        candidate_base = mapping['start'] - mapping['offset']
        bases[mapping['path']] = min(bases.get(mapping['path'], candidate_base), candidate_base)
    return bases


def code_location(address, mappings, bases):
    for mapping in mappings:
        if (mapping['start'] <= address < mapping['end'] and 'x' in mapping['perms']
                and mapping['path'] in bases):
            return mapping['path'], address - bases[mapping['path']]
    return None


def symbolize(symbolizer_path, module_path, module_offsets):
    request = '\n'.join(hex(offset) for offset in module_offsets) + '\n'
    completed = subprocess.run(
        [symbolizer_path, '--output-style=JSON', '--obj=' + module_path],
        input=request, capture_output=True, text=True, check=False)
    frames_by_offset = {}
    for line in completed.stdout.splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        frames = ['%s (%s:%s)' % (symbol.get('FunctionName', '??'),
                                  symbol.get('FileName', '??'), symbol.get('Line', 0))
                  for symbol in entry.get('Symbol', [])]
        frames_by_offset[int(entry['Address'], 16)] = frames or ['??']
    return frames_by_offset


def main():
    symbolizer_path, report_path = sys.argv[1], sys.argv[2]
    header, words, mappings = read_report(report_path)
    bases = load_bases(mappings)
    print(header)
    for _, _, line in words:
        if ' str="' in line:
            print('  ' + line)

    code_words = []
    for label, value, _ in words:
        location = code_location(value, mappings, bases)
        if location and (label.startswith('stack ') or label == 'reg rip'):
            code_words.append((label, value, location))

    # A return address points just past its call, so a stack word's caller
    # line is at offset - 1. rip is the faulting instruction itself, and - 1
    # there can fall off the start of the function.
    lookup_offsets = [(label, location, location[1] - (label != 'reg rip'))
                      for label, _, location in code_words]
    offsets_by_module = {}
    for _, (module_path, _), lookup_offset in lookup_offsets:
        offsets_by_module.setdefault(module_path, set()).add(lookup_offset)
    frames_by_module = {
        module_path: symbolize(symbolizer_path, module_path, sorted(module_offsets))
        for module_path, module_offsets in offsets_by_module.items()}

    for label, location, lookup_offset in lookup_offsets:
        module_path, module_offset = location
        frames = frames_by_module[module_path].get(lookup_offset, ['??'])
        print('  %-10s %s+%#x  %s' % (label.replace('reg ', ''),
                                      module_path.rsplit('/', 1)[-1], module_offset, frames[0]))
        for inlined_frame in frames[1:]:
            print('  %-10s   inlined by %s' % ('', inlined_frame))


if __name__ == '__main__':
    main()
