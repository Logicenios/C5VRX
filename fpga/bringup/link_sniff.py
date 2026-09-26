#!/usr/bin/env python3
"""Decode the FPGA -> C5 link frames mirrored on the BL616 USB-UART (top.v dbg_tx, 1 Mbaud).

  python3 bringup/link_sniff.py [/dev/ttyUSB1] [seconds] [--capture=PREFIX] [--clog=PREFIX]
Prints one line per frame with its arrival time. Uses the host framing of tools/link_cli.py.
--capture saves raw link captures (2048 words), --clog the colour-lock recordings (1024 16-bit
words = 256 line records, FPGA_CAPTURE offsets with bit 15 set; bringup/clog_analyze.py).
"""
import os
import sys
import termios
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from link_cli import crc16  # noqa: E402

NAMES = {1: "PING", 2: "GET_INFO", 3: "GET_SETTINGS", 4: "SET_CHANNEL", 5: "SCAN_START",
         6: "SET_STD_HINT", 7: "SET_FPGA_SETTINGS", 8: "SAVE_SETTINGS", 9: "FPGA_DEBUG", 10: "LINK_TEST",
         11: "FPGA_CAPTURE"}
from fpga_debug import debug_text  # noqa: E402

args = [a for a in sys.argv[1:] if not a.startswith("--")]
dev = args[0] if len(args) > 0 else "/dev/ttyUSB1"
secs = float(args[1]) if len(args) > 1 else 10.0
cap_prefix = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--capture=")), None)
cap_words, cap_count = {}, 0
clog_prefix = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--clog=")), None)
clog_words, clog_count = {}, 0
fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0; a[1] = 0; a[3] = 0
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[4] = a[5] = termios.B1000000
termios.tcsetattr(fd, termios.TCSANOW, a)
termios.tcflush(fd, termios.TCIFLUSH)
buf, t0, junk = b"", time.time(), 0
while time.time() - t0 < secs:
    try:
        buf += os.read(fd, 4096)
    except BlockingIOError:
        time.sleep(0.01)
    while len(buf) >= 8:
        i = buf.find(b"\xa5\x5a")
        if i < 0:
            junk += len(buf) - 1; buf = buf[-1:]; break
        junk += i; buf = buf[i:]
        if len(buf) < 6 or len(buf) < 8 + buf[5]:
            break
        n = buf[5]
        body, crc = buf[2:6 + n], buf[6 + n] | buf[7 + n] << 8
        if crc16(body) == crc:
            payload = buf[6:6 + n]
            if buf[3] == 11 and payload[1] & 0x80:             # colour-lock recording chunk
                off = (payload[0] | payload[1] << 8) & 0x3FFF
                clog_old = bool(payload[1] & 0x40)            # CLOG_AB firmware: old burst lock
                for i in range((n - 2) // 2):
                    clog_words[off + i] = payload[2 + 2 * i] | payload[3 + 2 * i] << 8
                if len(clog_words) >= 1024:
                    clog_count += 1
                    if clog_prefix:
                        name = f"{clog_prefix}{clog_count}{'_old' if clog_old else ''}.hex"
                        Path(name).write_text("".join(f"{clog_words.get(i, 0):04x}\n" for i in range(1024)))
                        print(f"{time.time() - t0:7.3f} s  colour-lock recording {clog_count} -> {name}", flush=True)
                    clog_words = {}
                buf = buf[8 + n:]
                continue
            if buf[3] == 11:                                  # raw capture chunk
                off = payload[0] | payload[1] << 8
                for i in range((n - 2) // 2):
                    cap_words[off + i] = payload[2 + 2 * i] | payload[3 + 2 * i] << 8
                if len(cap_words) >= 2048:
                    cap_count += 1
                    if cap_prefix:
                        name = f"{cap_prefix}{cap_count}.hex"
                        Path(name).write_text("".join(f"{cap_words.get(i, 0):04x}\n" for i in range(2048)))
                        print(f"{time.time() - t0:7.3f} s  capture {cap_count}: 2048 words -> {name}", flush=True)
                    cap_words = {}
                buf = buf[8 + n:]
                continue
            text = debug_text(payload) if buf[3] == 9 and n >= 16 else payload.hex()
            print(f"{time.time() - t0:7.3f} s  {NAMES.get(buf[3], hex(buf[3])):18s} {text}", flush=True)
            buf = buf[8 + n:]
        else:
            junk += 1; buf = buf[1:]
print(f"(bytes outside valid frames, incl. stale buffer data: {junk})")
