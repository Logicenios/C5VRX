#!/usr/bin/env python3
"""Decode the FPGA diagnostics echoed on the C5 console (src/link.c prints each FPGA_DEBUG frame
as a "[FPGADBG] <hex>" line). Use it when the Tang Nano has no host USB connection, e.g. while
it runs from flash on a separate power supply.

  python3 bringup/c5_fpgadbg.py [/dev/ttyACM0] [seconds]
Prints the decoded frames, and a line whenever no frame arrived for more than 2.5 s (the FPGA
sends one per second, so a gap means its control CPU or the link has stopped).
"""
import os
import sys
import termios
import time

from fpga_debug import debug_text

args = [a for a in sys.argv[1:] if not a.startswith("--")]
dev = args[0] if len(args) > 0 else "/dev/ttyACM0"
secs = float(args[1]) if len(args) > 1 else 10.0
fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0; a[1] = 0; a[3] = 0
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[4] = a[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)

t0 = time.monotonic()
last = t0
warned = False
buf = b""
while time.monotonic() - t0 < secs:
    try:
        buf += os.read(fd, 4096)
    except BlockingIOError:
        time.sleep(0.02)
    now = time.monotonic()
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        i = line.find(b"[FPGADBG] ")
        if i < 0:
            continue
        hexs = line[i + 10:].strip()
        try:
            p = bytes.fromhex(hexs.decode())
        except ValueError:
            continue
        print(f"{now - t0:7.3f} s  {debug_text(p)}", flush=True)
        last, warned = now, False
    if now - last > 2.5 and not warned:
        print(f"{now - t0:7.3f} s  no FPGA_DEBUG for {now - last:.1f} s", flush=True)
        warned = True
os.close(fd)
