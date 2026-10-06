#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["capstone==5.0.7"]
# ///
"""Instruction mix of a counted compare: which instructions we retire more.

    PERF_KEEP_INSN_DATA=1 playwright/bench/local-counted-compare.sh chromium official <img>
    playwright/bench/perf-insn-mix.py tmp/counted-official-chromium <bin_dir> \
        [--census symtab.nm.gz] [--kernels goto_warm,layout_text]

Reads <arm>-<kernel>-insn.data (perf record -e instructions, kept by
PERF_KEEP_INSN_DATA=1), maps every sampled ip in the browser binary, libc and
libharfbuzz back to a virtual address, decodes it with capstone, and prints per
kernel, in M instructions / iter (each share scaled by the `instructions / iter`
row of the same directory's report.md): DSO groups, opcode classes, idioms
(trap guards, stack-protector canaries, CFI rotates, indirect calls), top
mnemonics, the (DSO, mnemonic) rows we retire most in excess, musl functions,
and, with --census (the chain's chromium-link-census symtab.nm.gz), our hottest
browser functions.

<bin_dir>/ours and <bin_dir>/official hold the files the arms mapped, copied out
of the two images (`docker create` + `docker cp`: the chrome-headless-shell-linux64
dir, ld-musl-x86_64.so.1 + libharfbuzz.so.* for ours, libc.so.6 for official),
matched by basename.
"""
import argparse
import bisect
import collections
import gzip
import pathlib
import re
import subprocess
import sys

ARMS = ('alpine', 'official')
PERF_COMMAND = {
    'alpine': ('perf-alpine:counted', 'perf'),
    'official': ('perf-official:counted', '/usr/local/bin/perf-real'),
}
BIN_SUBDIR = {'alpine': 'ours', 'official': 'official'}
MMAP_LINE = re.compile(
    r'PERF_RECORD_MMAP2 .*\[0x([0-9a-f]+)\(0x([0-9a-f]+)\) @ 0x([0-9a-f]+|0) .*\]: r-xp (\S+)')
MMAP_LINE_ZERO = re.compile(
    r'PERF_RECORD_MMAP2 .*\[0x([0-9a-f]+)\(0x([0-9a-f]+)\) @ (0) .*\]: r-xp (\S+)')
SAMPLE_LINE = re.compile(r'^\s*(-?\d+)\s+(\d+)\s+([0-9a-f]+) \((.*)\)$')
CONTEXT_AFTER = 4


def perf_script_lines(arm, data_path):
    image, perf_binary = PERF_COMMAND[arm]
    command = ['docker', 'run', '--rm', '--user', '0', '-v', f'{data_path.parent.resolve()}:/d:ro',
               '--entrypoint', perf_binary, image, 'script', '-f',
               '-i', f'/d/{data_path.name}', '--show-mmap-events',
               '-F', 'pid,period,ip,dso']
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True)
    yield from process.stdout
    process.wait()


def load_segments(elf_path):
    """(p_offset, p_vaddr, p_filesz) of each executable LOAD segment."""
    output = subprocess.run(['readelf', '-lW', str(elf_path)], capture_output=True,
                            text=True, check=True).stdout
    segments = []
    for line in output.splitlines():
        fields = line.split()
        if fields[:1] == ['LOAD'] and 'E' in fields[6:-1]:
            segments.append((int(fields[1], 16), int(fields[2], 16), int(fields[4], 16)))
    return segments


def read_samples(arm, data_path, files_by_basename):
    """{(basename, vaddr): period} for mapped files, plus period per other DSO."""
    mappings = collections.defaultdict(list)
    weights = collections.Counter()
    other_weights = collections.Counter()
    segments = {name: load_segments(path) for name, path in files_by_basename.items()}
    for line in perf_script_lines(arm, data_path):
        if 'PERF_RECORD_MMAP2' in line:
            match = MMAP_LINE.search(line) or MMAP_LINE_ZERO.search(line)
            if match:
                start, length, page_offset, path = match.groups()
                name = path.rsplit('/', 1)[-1]
                if name in files_by_basename:
                    mappings[name].append((int(start, 16), int(length, 16), int(page_offset, 16)))
            continue
        match = SAMPLE_LINE.match(line)
        if not match:
            continue
        _, period, ip_text, dso_path = match.groups()
        name = dso_path.rsplit('/', 1)[-1]
        if name not in files_by_basename:
            other_weights[other_label(dso_path)] += int(period)
            continue
        ip = int(ip_text, 16)
        vaddr = None
        for start, length, page_offset in mappings[name]:
            if start <= ip < start + length:
                file_offset = ip - start + page_offset
                for segment_offset, segment_vaddr, segment_size in segments[name]:
                    if segment_offset <= file_offset < segment_offset + segment_size:
                        vaddr = file_offset - segment_offset + segment_vaddr
                break
        if vaddr is None:
            other_weights['unmapped ' + name] += int(period)
        else:
            weights[(name, vaddr)] += int(period)
    return weights, other_weights


def other_label(dso_path):
    if dso_path.startswith('[kernel'):
        return 'kernel'
    if dso_path.startswith('[JIT') or '/tmp/perf-' in dso_path:
        return 'node JIT'
    if dso_path.endswith('/node'):
        return 'node'
    return dso_path.rsplit('/', 1)[-1]


def disassemble(elf_path, wanted_addresses):
    """{vaddr: (mnemonic, operands, [next instructions])} plus {trap vaddr: kind}.

    A sampled ip is always an instruction boundary, and so is a branch
    target, so each is decoded forward from its own address."""
    import capstone
    decoder = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    decoder.syntax = capstone.CS_OPT_SYNTAX_INTEL
    image = elf_path.read_bytes()
    segments = load_segments(elf_path)

    def decode(address, count):
        for segment_offset, segment_vaddr, segment_size in segments:
            if segment_vaddr <= address < segment_vaddr + segment_size:
                file_offset = address - segment_vaddr + segment_offset
                window = image[file_offset:file_offset + 15 * count]
                return [(insn.address, insn.mnemonic, insn.op_str)
                        for insn in decoder.disasm(window, address, count)]
        return []

    decoded, traps = {}, {}
    for address in wanted_addresses:
        instructions = decode(address, CONTEXT_AFTER + 1)
        if not instructions or instructions[0][0] != address:
            continue
        decoded[address] = (instructions[0][1], instructions[0][2], instructions[1:])
        for _, mnemonic, operands in instructions:
            target = branch_target(operands) if mnemonic.startswith('j') else None
            if target is not None and target not in traps:
                landing = decode(target, 1)
                kind = landing[0][1] if landing else ''
                traps[target] = ('ud2' if kind == 'ud2' else 'ud1') if kind.startswith('ud') else None
    return decoded, {address: kind for address, kind in traps.items() if kind}


def branch_target(operands):
    match = re.match(r'^(0x[0-9a-f]+|[0-9a-f]+)\b', operands)
    return int(match.group(1), 16) if match else None


def opcode_class(mnemonic, operands):
    if mnemonic.startswith(('rep', 'repe', 'repne')) and any(
            op in mnemonic for op in ('stos', 'movs', 'cmps', 'scas')):
        return 'rep string'
    if 'zmm' in operands:
        return 'simd zmm'
    if 'ymm' in operands:
        return 'simd ymm'
    if 'xmm' in operands:
        return 'simd xmm'
    if mnemonic.startswith('ud'):
        return 'ud trap'
    if mnemonic in ('call', 'notrack call'):
        return 'call'
    if mnemonic == 'ret':
        return 'ret'
    if mnemonic in ('jmp', 'notrack jmp'):
        return 'jmp'
    if mnemonic.startswith('j'):
        return 'jcc'
    if mnemonic in ('cmp', 'test'):
        return 'cmp/test'
    if mnemonic in ('mov', 'movabs'):
        return 'mov'
    if mnemonic.startswith(('movzx', 'movsx')):
        return 'movzx/movsx'
    if mnemonic == 'lea':
        return 'lea'
    if mnemonic in ('push', 'pop'):
        return 'push/pop'
    if mnemonic in ('add', 'sub', 'and', 'or', 'xor', 'inc', 'dec', 'neg', 'not', 'adc', 'sbb'):
        return 'alu'
    if mnemonic in ('shl', 'shr', 'sar', 'rol', 'ror', 'shld', 'shrd', 'shlx', 'shrx', 'sarx', 'rorx'):
        return 'shift/rotate'
    if mnemonic.startswith(('imul', 'mul', 'div', 'idiv')):
        return 'mul/div'
    if mnemonic.startswith(('set', 'cmov')):
        return 'setcc/cmov'
    if mnemonic.startswith('nop'):
        return 'nop'
    if mnemonic in ('bt', 'bts', 'btr', 'btc', 'bsf', 'bsr', 'tzcnt', 'lzcnt', 'popcnt', 'bswap'):
        return 'bit ops'
    if mnemonic.startswith('lock') or mnemonic.startswith(('xchg', 'cmpxchg', 'xadd')):
        return 'atomic'
    return 'other'


def idioms(address, mnemonic, operands, following, traps):
    """Idiom labels this sampled instruction belongs to."""
    found = []
    if 'fs:[0x28]' in operands:
        found.append('stack-protector canary')
    if mnemonic in ('rol', 'ror') and re.search(r', (0x)?[0-9a-f]+$', operands):
        found.append('rotate by immediate (CFI index)')
    if mnemonic in ('call', 'notrack call') and branch_target(operands) is None:
        found.append('indirect call')
    # A guard is a jcc into a trap, or the compare block that feeds one, up to
    # the jcc within the next few instructions, with no call or jump between.
    block = [(address, mnemonic, operands)] + following
    for index, (_, block_mnemonic, block_operands) in enumerate(block):
        if block_mnemonic in ('call', 'ret', 'jmp', 'notrack call', 'notrack jmp'):
            break
        if block_mnemonic.startswith('j'):
            target = branch_target(block_operands)
            kind = traps.get(target)
            if kind is None and index + 1 < len(block) and block[index + 1][1].startswith('ud'):
                kind = 'ud2' if block[index + 1][1] == 'ud2' else 'ud1'
            if kind:
                found.append(f'trap guard ({kind})')
            break
        if block_mnemonic.startswith('ud'):
            break
    return found


def read_instructions_per_iteration(report_path):
    """{kernel: M instructions per iteration} per arm, from report.md."""
    rates = collections.defaultdict(dict)
    kernel = None
    for line in report_path.read_text().splitlines():
        match = re.match(r'^`(\w+)` per iteration / per instruction', line)
        if match:
            kernel = match.group(1)
        match = re.match(r'^\| instructions / iter \| ([^|]+) \| ([^|]+) \|', line)
        if match and kernel:
            rates[kernel]['alpine'] = float(match.group(1))
            rates[kernel]['official'] = float(match.group(2))
    return rates


def load_census(census_path):
    starts, names = [], []
    with gzip.open(census_path, 'rt', errors='replace') as census:
        for line in census:
            fields = line.split(None, 3)
            if len(fields) == 4 and fields[2] in 'tTW' and int(fields[1], 16) > 0:
                starts.append(int(fields[0], 16))
                names.append(fields[3].strip())
    return starts, names


def load_dynamic_symbols(elf_path):
    # musl exports every libc function, so its dynsym names each sample;
    # glibc's IFUNC variants (__memset_avx2_*) are not exported and would be
    # misnamed after the preceding export, so only ours is named this way.
    output = subprocess.run(['nm', '-D', '-n', '-S', '--defined-only', str(elf_path)],
                            capture_output=True, text=True, check=False).stdout
    starts, names = [], []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 4 and fields[2] in 'tTiW' and (not starts or starts[-1] != int(fields[0], 16)):
            starts.append(int(fields[0], 16))
            names.append((fields[3], int(fields[1], 16)))
    return starts, names


def demangle(names):
    if not names:
        return {}
    output = subprocess.run(['llvm-cxxfilt-20'], input='\n'.join(names), capture_output=True,
                            text=True, check=False).stdout.splitlines()
    return dict(zip(names, output))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('counted_dir', type=pathlib.Path)
    parser.add_argument('bin_dir', type=pathlib.Path)
    parser.add_argument('--census', type=pathlib.Path)
    parser.add_argument('--suffix', default='-insn')
    parser.add_argument('--kernels')
    arguments = parser.parse_args()

    rates = read_instructions_per_iteration(arguments.counted_dir / 'report.md')
    kernels = (arguments.kernels.split(',') if arguments.kernels else sorted(
        {path.name.split('-', 1)[1][:-len(arguments.suffix + '.data')]
         for path in arguments.counted_dir.glob(f'alpine-*{arguments.suffix}.data')}))
    files = {arm: {path.name: path for path in (arguments.bin_dir / BIN_SUBDIR[arm]).rglob('*')
                   if path.is_file() and path.stat().st_size > 100000
                   and path.read_bytes()[:4] == b'\x7fELF'}
             for arm in ARMS}

    samples = {}
    for kernel in kernels:
        for arm in ARMS:
            data_path = arguments.counted_dir / f'{arm}-{kernel}{arguments.suffix}.data'
            if data_path.exists():
                samples[(arm, kernel)] = read_samples(arm, data_path, files[arm])
                print(f'read {data_path.name}', file=sys.stderr)

    decoded, traps = {}, {}
    for arm in ARMS:
        for name, path in files[arm].items():
            wanted = {vaddr for (sample_arm, _), (weights, _) in samples.items()
                      if sample_arm == arm for (sample_name, vaddr) in weights
                      if sample_name == name}
            decoded[(arm, name)], traps[(arm, name)] = disassemble(path, wanted)
            print(f'disassembled {arm} {name}: {len(wanted)} addresses', file=sys.stderr)

    census = None
    if arguments.census:
        census = load_census(arguments.census)

    musl_symbols = {}
    for kernel in kernels:
        if not all((arm, kernel) in samples for arm in ARMS):
            continue
        class_weights = {arm: collections.Counter() for arm in ARMS}
        idiom_weights = {arm: collections.Counter() for arm in ARMS}
        dso_weights = {arm: collections.Counter() for arm in ARMS}
        mnemonic_weights = {arm: collections.Counter() for arm in ARMS}
        group_mnemonic_weights = {arm: collections.Counter() for arm in ARMS}
        function_weights = collections.Counter()
        function_guard_weights = collections.Counter()
        libc_function_weights = collections.Counter()
        total = {}
        for arm in ARMS:
            weights, other_weights = samples[(arm, kernel)]
            total[arm] = sum(weights.values()) + sum(other_weights.values())
            for label, weight in other_weights.items():
                dso_weights[arm][label] += weight
            for (name, vaddr), weight in weights.items():
                group = 'browser binary' if name.startswith('chrome') else (
                    'libc' if name.startswith(('ld-musl', 'libc.so')) else name)
                dso_weights[arm][group] += weight
                entry = decoded[(arm, name)].get(vaddr)
                if entry is None:
                    class_weights[arm]['undecoded'] += weight
                    group_mnemonic_weights[arm][group + ' undecoded'] += weight
                    continue
                mnemonic, operands, following = entry
                group_mnemonic_weights[arm][group + ' ' + mnemonic] += weight
                class_weights[arm][opcode_class(mnemonic, operands)] += weight
                mnemonic_weights[arm][mnemonic] += weight
                labels = idioms(vaddr, mnemonic, operands, following, traps[(arm, name)])
                for label in labels:
                    idiom_weights[arm][label] += weight
                if arm == 'alpine' and name.startswith('ld-musl'):
                    if name not in musl_symbols:
                        musl_symbols[name] = load_dynamic_symbols(files['alpine'][name])
                    starts, symbols = musl_symbols[name]
                    index = bisect.bisect_right(starts, vaddr) - 1
                    symbol_name, symbol_size = symbols[index] if index >= 0 else ('?', 0)
                    if symbol_size and vaddr >= starts[index] + symbol_size:
                        symbol_name = f'static after {symbol_name}'
                    libc_function_weights[symbol_name] += weight
                if census and arm == 'alpine' and name.startswith('chrome'):
                    index = bisect.bisect_right(census[0], vaddr) - 1
                    function_name = census[1][index] if index >= 0 else '?'
                    function_weights[function_name] += weight
                    if any(label.startswith('trap guard') for label in labels):
                        function_guard_weights[function_name] += weight

        per_iteration = {arm: rates.get(kernel, {}).get(arm) for arm in ARMS}
        unit = 'M insn/iter' if all(per_iteration.values()) else '% of samples'

        def scaled(arm, weight):
            if all(per_iteration.values()):
                return weight / total[arm] * per_iteration[arm]
            return 100 * weight / total[arm]

        def table(title, weights, limit=None, minimum=0.0, by_delta=False):
            def sort_key(name):
                if by_delta:
                    return -(scaled('alpine', weights['alpine'][name])
                             - scaled('official', weights['official'][name]))
                return -max(scaled(a, weights[a][name]) for a in ARMS)
            names = sorted(set(weights['alpine']) | set(weights['official']), key=sort_key)
            rows = []
            for name in names[:limit]:
                ours, theirs = (scaled(arm, weights[arm][name]) for arm in ARMS)
                if max(ours, theirs) < minimum:
                    continue
                ratio = f'{ours / theirs:.2f}x' if theirs else '—'
                rows.append(f'| `{name}` | {ours:.2f} | {theirs:.2f} | {ours - theirs:+.2f} | {ratio} |')
            print(f'\n{title} ({unit}, alpine vs official):\n')
            print('| class | alpine | official | delta | ratio |')
            print('|---|---:|---:|---:|---:|')
            print('\n'.join(rows))

        print(f'\n### `{kernel}`')
        print(f'\ninstructions / iter: alpine {per_iteration["alpine"]} M vs official '
              f'{per_iteration["official"]} M')
        table('By DSO group', dso_weights, minimum=0.05 * (1 if unit == 'M insn/iter' else 0))
        table('By opcode class (browser binary + libc + harfbuzz)', class_weights)
        table('By idiom (an instruction can carry several)', idiom_weights)
        table('Top mnemonics', mnemonic_weights, limit=25)
        # libharfbuzz is a separate DSO in ours and inside the binary in
        # official, so it joins the browser binary for this comparison.
        merged_weights = {arm: collections.Counter() for arm in ARMS}
        for arm in ARMS:
            for name, weight in group_mnemonic_weights[arm].items():
                merged_weights[arm][re.sub(r'^libharfbuzz\.so\S*', 'browser binary', name)] += weight
        table('Most excess instructions, ours over official (DSO group + mnemonic)',
              merged_weights, limit=20, by_delta=True)
        if libc_function_weights:
            print(f'\nalpine libc (musl), hottest functions ({unit}):\n')
            for name, weight in libc_function_weights.most_common(10):
                print(f'- {scaled("alpine", weight):.2f}  `{name}`')
        if function_weights:
            names = demangle([n for n, _ in function_weights.most_common(25)]
                             + [n for n, _ in function_guard_weights.most_common(12)])
            print(f'\nalpine browser binary, hottest functions ({unit}):\n')
            for name, weight in function_weights.most_common(25):
                print(f'- {scaled("alpine", weight):.2f}  `{names.get(name, name)[:160]}`')
            print(f'\nalpine browser binary, functions with the most trap-guard instructions ({unit}):\n')
            for name, weight in function_guard_weights.most_common(12):
                print(f'- {scaled("alpine", weight):.2f}  `{names.get(name, name)[:160]}`')


if __name__ == '__main__':
    main()
