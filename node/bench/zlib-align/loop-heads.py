"""Prints where deflate's two hot loops start in a binary.

insert_loop: the innermost loop holding the hash multiply (imul $0x103d9).
compare_loop: the innermost loop holding longest_match's bound check
(cmp $0xfa), reported unmatched when absent (gcc's shape). node's PGO build inlines longest_match into deflate_slow; the
harness keeps it out of line, so both functions are searched. Exits non-zero
naming what it could not find, so a changed codegen never reads as a
placement.
"""
import re
import subprocess
import sys

binary_path, arm_name = sys.argv[1], sys.argv[2]
symbol_rows = subprocess.run(['nm', '-S', binary_path], capture_output=True, text=True, check=True).stdout


def function_loops(function_name):
    # ThinLTO renames a promoted local to <name>.llvm.<hash>.
    function_rows = [row.split() for row in symbol_rows.splitlines()
                     if re.search(rf' {function_name}(\.llvm\.\d+)?$', row)]
    if not function_rows:
        return [], []
    # node links a second, smaller deflate_slow; the hot one is the largest.
    largest_row = max(function_rows, key=lambda row: int(row[1], 16))
    function_start, function_size = int(largest_row[0], 16), int(largest_row[1], 16)
    disassembly = subprocess.run(
        ['objdump', '-d', '--no-show-raw-insn', f'--start-address={function_start:#x}',
         f'--stop-address={function_start + function_size:#x}', binary_path],
        capture_output=True, text=True, check=True).stdout
    instruction_rows = []
    for row in disassembly.splitlines():
        row_match = re.match(r'\s+([0-9a-f]+):\t(.*)', row)
        if row_match:
            instruction_rows.append((int(row_match.group(1), 16), row_match.group(2).strip()))
    loop_spans = []
    for row_index, (address, text) in enumerate(instruction_rows):
        jump_match = re.match(r'j\w+\s+([0-9a-f]+)', text)
        if jump_match and function_start <= int(jump_match.group(1), 16) <= address:
            loop_end = instruction_rows[row_index + 1][0] if row_index + 1 < len(instruction_rows) else address + 2
            loop_spans.append((int(jump_match.group(1), 16), loop_end))
    return instruction_rows, loop_spans


slow_rows, slow_spans = function_loops('deflate_slow')
if not slow_rows:
    sys.exit(f'{arm_name}: no deflate_slow symbol')
match_rows, match_spans = function_loops('longest_match')
fortify_traps = sum(1 for _, text in slow_rows + match_rows if text.startswith('ud2'))


def innermost_loop(marker_pattern, loop_label, required=True):
    for function_name, instruction_rows, loop_spans in (
            ('deflate_slow', slow_rows, slow_spans), ('longest_match', match_rows, match_spans)):
        marker_addresses = [address for address, text in instruction_rows if re.search(marker_pattern, text)]
        holding_spans = [span for span in loop_spans
                         if any(span[0] <= address < span[1] for address in marker_addresses)]
        if holding_spans:
            loop_head, loop_end = min(holding_spans, key=lambda span: span[1] - span[0])
            return (f'{loop_label}@{function_name} head%32={loop_head % 32} head%64={loop_head % 64} '
                    f'bytes={loop_end - loop_head} lines64={(loop_end - 1) // 64 - loop_head // 64 + 1}')
    if required:
        sys.exit(f'{arm_name}: no loop in deflate_slow or longest_match holds {loop_label} ({marker_pattern})')
    return f'{loop_label}=unmatched (no loop holds {marker_pattern})'


insert_summary = innermost_loop(r'imul\s+\$0x103d9', 'insert_loop')
# gcc shapes the compare loop without the 0xfa bound, so it may not match.
compare_summary = innermost_loop(r'cmp\s+\$0xfa,', 'compare_loop', required=False)
print(f'{arm_name}: ud2={fortify_traps} {insert_summary} · {compare_summary}')
