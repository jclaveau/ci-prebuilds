#!/usr/bin/env python3
"""Clear DF_BIND_NOW / DF_1_NOW on every ELF under a directory, in place.

Alpine's toolchain links `-z now` by default, so our whole WebKit bundle binds
eagerly: the loader resolves every symbol in every one of the 60 libraries at
load time. Playwright's own build does not — its dynamic section carries
neither flag — so it resolves only what it actually calls.

That asymmetry is now the leading explanation for `launch` (1.34). A profile of
the launch kernel puts the top cost, on both arms, in the dynamic loader, and
the hot address in ours resolves to musl's `gnu_lookup_filtered` — symbol
lookup, ~5.2% of all samples against official's ~3.5% loader cluster.

Flipping it needs no rebuild. `-z now` only sets two bits in the dynamic
section; the PLT stubs are emitted either way, so clearing the bits hands the
same binary back to the loader as a lazily-bound one. That makes the
experiment a tag and a probe rather than a multi-hour build, which is the only
reason to do it this way — if it pays, it belongs in the link flags.

usage: clear-bind-now.py <dir> [<dir> ...]
"""
import struct
import sys
from pathlib import Path

DT_NULL = 0
DT_FLAGS = 30
DT_FLAGS_1 = 0x6FFFFFFB
DF_BIND_NOW = 0x8
DF_1_NOW = 0x1
PT_DYNAMIC = 2


def clear(path):
    data = bytearray(path.read_bytes())
    if data[:4] != b"\x7fELF" or data[4] != 2:
        return None
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)

    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", data, off)
        if p_type != PT_DYNAMIC:
            continue
        # p_offset is the file position; p_vaddr would need the mapping.
        p_offset, = struct.unpack_from("<Q", data, off + 0x08)
        touched = []
        pos = p_offset
        while True:
            tag, val = struct.unpack_from("<QQ", data, pos)
            if tag == DT_NULL:
                break
            if tag == DT_FLAGS and val & DF_BIND_NOW:
                struct.pack_into("<Q", data, pos + 8, val & ~DF_BIND_NOW)
                touched.append("DF_BIND_NOW")
            elif tag == DT_FLAGS_1 and val & DF_1_NOW:
                struct.pack_into("<Q", data, pos + 8, val & ~DF_1_NOW)
                touched.append("DF_1_NOW")
            pos += 16
        if touched:
            path.write_bytes(bytes(data))
            return touched
        return []
    return None


def main(dirs):
    patched = skipped = 0
    for d in dirs:
        for path in sorted(Path(d).rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            try:
                touched = clear(path)
            except (struct.error, IndexError):
                # Not our business: a data file that happens to start with the
                # magic, or a truncated one. Report rather than fail the run.
                print(f"unparsed: {path}", file=sys.stderr)
                continue
            if touched is None:
                continue
            if touched:
                patched += 1
            else:
                skipped += 1
    print(f"cleared bind-now on {patched} ELFs, {skipped} already lazy")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
