#!/usr/bin/env python3
"""Decode the FPGA -> C5 link frames mirrored on the BL616 USB-UART (top.v dbg_tx, 1 Mbaud).

  python3 bringup/link_sniff.py [/dev/ttyUSB1] [seconds]
Prints one line per frame with its arrival time. Uses the host framing of tools/link_cli.py.
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
MODES = ["60", "59.94", "50", "?"]
CAUSE = ["-", "PLL A lock", "PLL B lock", "mode change"]


WT = ["not seen", "running", "done"]


def debug_text(p: bytes) -> str:
    import struct
    st, dbg, ms, cnt = struct.unpack("<IIII", p[:16])
    text = (f"ms={ms} status={st:08x} [pll={st >> 6 & 1} sdram={st >> 7 & 1} vlock={st >> 2 & 1} "
            f"strobe={st >> 10 & 1} nosig={st >> 11 & 1} mode={MODES[st >> 8 & 3]}] "
            f"mode_req={MODES[dbg >> 8 & 3]} want={MODES[dbg >> 10 & 3]} restarts={dbg >> 16 & 255} "
            f"cause={CAUSE[dbg >> 12 & 3]} rate_changes={dbg >> 24}")
    if len(p) >= 36:
        wt, freq, ep, en, bits = struct.unpack("<5I", p[16:36])
        state, bad = wt >> 28, wt & 0x1FF
        wiring = WT[state] if state < 3 else "?"
        if state == 2:
            wiring = "OK" if not bad else "FAULT on " + ",".join(
                ("STROBE" if j == 8 else f"D{j}") for j in range(9) if bad >> j & 1)
        mhz = freq / 1e6
        act = "".join("+" if (bits >> j & 1) and (bits >> (8 + j) & 1) else "-" for j in range(8))
        ppm = lambda e: f"{e / max(freq, 1) * 1e6:.0f}"
        text += (f"\n            link: wiring {wiring} (runs {wt >> 16 & 0xFFF}), strobe {mhz:.6f} MHz, "
                 f"bits D0..D7 {act}, edge errors rise {ppm(ep)} ppm fall {ppm(en)} ppm")
        if len(p) >= 57 and state == 2:
            r = p[36:57]
            text += (f"\n            wiring samples (hex, bit j = D j): zero {r[0]:02x} ones " + " ".join(f"{b:02x}" for b in r[1:10])
                     + " zeros " + " ".join(f"{b:02x}" for b in r[10:19]) + f" end {r[19]:02x}; false starts {r[20]}")
    return text
args = [a for a in sys.argv[1:] if not a.startswith("--")]
dev = args[0] if len(args) > 0 else "/dev/ttyUSB1"
secs = float(args[1]) if len(args) > 1 else 10.0
cap_prefix = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--capture=")), None)
cap_words, cap_count = {}, 0
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
