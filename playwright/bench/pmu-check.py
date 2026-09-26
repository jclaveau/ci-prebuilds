#!/usr/bin/env python3
"""Exit 0 when this machine counts retired instructions, 1 when it cannot.

Hosted runners pass the PMU through on some CPU models and not others, and a
counted comparison is worthless without it. The runner has no perf binary, so
this opens the counter directly with perf_event_open and checks it moved.
"""
import ctypes
import os
import struct
import sys

SYS_PERF_EVENT_OPEN = 298  # x86_64
PERF_TYPE_HARDWARE = 0
PERF_COUNT_HW_INSTRUCTIONS = 1
PERF_EVENT_IOC_ENABLE = 0x2400
PERF_EVENT_IOC_DISABLE = 0x2401
# disabled | exclude_kernel | exclude_hv
ATTR_FLAGS = 1 | 1 << 5 | 1 << 6

libc = ctypes.CDLL(None, use_errno=True)
attr = struct.pack('IIQQQQQ', PERF_TYPE_HARDWARE, 64,
                   PERF_COUNT_HW_INSTRUCTIONS, 0, 0, 0, ATTR_FLAGS).ljust(64, b'\0')
counter_fd = libc.syscall(SYS_PERF_EVENT_OPEN, ctypes.c_char_p(attr), 0, -1, -1, 0)
if counter_fd < 0:
    print(f'no PMU: perf_event_open failed, {os.strerror(ctypes.get_errno())}')
    sys.exit(1)

libc.ioctl(counter_fd, PERF_EVENT_IOC_ENABLE, 0)
busy_total = sum(range(100000))
libc.ioctl(counter_fd, PERF_EVENT_IOC_DISABLE, 0)
instruction_count = struct.unpack('Q', os.read(counter_fd, 8))[0]
if instruction_count == 0:
    print('no PMU: the instructions counter opened but never moved')
    sys.exit(1)
print(f'PMU ok: {instruction_count} instructions counted')
