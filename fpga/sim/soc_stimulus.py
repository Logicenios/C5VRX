#!/usr/bin/env python3
"""C5-side stimulus for tb_soc.v: timed bytes the testbench plays into the FPGA's link_rx,
framed with the host encoder of tools/link_cli.py (same protocol as src/link_proto.h).
Output lines: one 40-bit hex word per line, {time_us[31:0], byte[7:0]}."""
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from link_cli import STATUS_FMT, encode  # noqa: E402

SETTINGS, STATUS, SCAN_RESULT, SCAN_DONE = 0x83, 0x84, 0x85, 0x86
events = []


def at(ms: float, frame: bytes) -> None:
    t = int(ms * 1000)
    for i, b in enumerate(frame):
        events.append((t + i * 10, b))            # 1 Mbaud: 10 us per byte


# SETTINGS reply: channel 8 (A1), std AUTO, no blob yet
at(50, encode(SETTINGS, 0, bytes([8, 0, 0])))
# STATUS at 10 Hz: A1 5865 MHz, then A6 5765 MHz (after the test tunes index 13), strength 70
for k in range(26):
    ch = 8 if k < 20 else 13
    freq = 5865 if ch == 8 else 5765                 # A1 / A6 (src/rf.c table)
    at(60 + 100 * k, encode(STATUS, k, struct.pack(STATUS_FMT, ch, freq, 43, 70, 25, 99, 6,
                                                   -141, -1022, -50, 972, 1, 0)))
# scan results after the SCAN_START the test presses at ~1.4 s
for i in range(48):
    q = 90 if i == 13 else (i * 7) % 40
    at(1600 + i * 2, encode(SCAN_RESULT, i, bytes([i, q, 20, 50])))
at(1720, encode(SCAN_DONE, 0, bytes([13, 1])))

events.sort()
Path(sys.argv[1]).write_text("".join(f"{t:08x}{b:02x}\n" for t, b in events))
print(f"{len(events)} bytes")
