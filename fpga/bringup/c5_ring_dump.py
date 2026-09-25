#!/usr/bin/env python3
"""Fetch the C5's raw I/Q ring over its USB console (`R` command in src/video.c).

  python3 bringup/c5_ring_dump.py /dev/ttyACM0 OUT.hex
OUT.hex: one byte per line ({I[3:0], Q[3:0]}, 40 MS/s, 28672 continuous samples), the format
of the sim testbenches' $readmemh (e.g. sim/tb_chain_a.v, sim/tb_full.v).
"""
import os
import sys
import termios
import time

dev, out = sys.argv[1], sys.argv[2]
fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd); a[3] = 0; termios.tcsetattr(fd, termios.TCSANOW, a)
time.sleep(0.2)
try:
    while os.read(fd, 65536): pass
except BlockingIOError:
    pass
os.write(fd, b"R")
buf, t0 = b"", time.time()
while time.time() - t0 < 10 and b"[RING] END" not in buf:
    try:
        buf += os.read(fd, 65536)
    except BlockingIOError:
        time.sleep(0.02)
txt = buf.decode(errors="replace")
i, j = txt.find("[RING] BEGIN"), txt.find("[RING] END")
if i < 0 or j < 0:
    sys.exit("no complete ring dump received")
lines = [l.strip() for l in txt[i:j].splitlines()[1:] if len(l.strip()) == 128]
data = bytes.fromhex("".join(lines))
open(out, "w").write("".join(f"{b:02x}\n" for b in data))
print(f"{len(data)} samples -> {out}")
