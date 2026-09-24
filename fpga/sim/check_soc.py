#!/usr/bin/env python3
"""Check tb_soc.v logs: decode the FPGA->C5 frames and look for the expected OSD text."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from link_cli import crc16  # noqa: E402

raw = [(int(t), int(b, 16)) for t, b in (l.split() for l in open("data/soc_tx.txt") if l.strip())]
data = bytes(b for _, b in raw)
frames, i = [], 0
while i + 8 <= len(data):
    if data[i] == 0xA5 and data[i + 1] == 0x5A:
        n = data[i + 5]
        body = data[i + 2:i + 6 + n]
        crc = data[i + 6 + n] | data[i + 7 + n] << 8
        if crc16(body) == crc:
            frames.append((raw[i][0], data[i + 3], bytes(data[i + 6:i + 6 + n])))
            i += 8 + n
            continue
    i += 1
names = {1: "PING", 2: "GET_INFO", 3: "GET_SETTINGS", 4: "SET_CHANNEL", 5: "SCAN_START",
         6: "SET_STD_HINT", 7: "SET_FPGA_SETTINGS", 8: "SAVE_SETTINGS", 9: "FPGA_DEBUG", 10: "LINK_TEST"}
for t, ty, p in frames:
    print(f"  {t:5d} ms  {names.get(ty, hex(ty)):18s} {p.hex()}")
osd = Path("data/soc_osd.txt").read_text()
import struct
dbg = [p for _, ty, p in frames if ty == 9 and len(p) >= 36]
wt = struct.unpack("<9I", dbg[-1][:36])[4] if dbg else 0
wt_state, wt_bad, wt_strobe = wt >> 28, wt & 0x1FF, wt >> 12 & 3
expect_bad = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0
print(f"wiring test: state {wt_state} (2 = done), faulty lines mask {wt_bad:03x} (expect {expect_bad:03x}), strobe code {wt_strobe}")
print(osd)
checks = {
    "wiring test detected and evaluated": wt_state == 2,
    "wiring verdict (faulty-line mask)": wt_bad == expect_bad,
    "GET_SETTINGS sent": any(ty == 3 for _, ty, _ in frames),
    "GET_SETTINGS stops after SETTINGS": not any(ty == 3 and t > 600 for t, ty, _ in frames),
    "SCAN_START on long press": any(ty == 5 and 1250 <= t <= 1400 for t, ty, _ in frames),
    "SET_CHANNEL 13 (best) on short press": any(ty == 4 and p == bytes([13]) for _, ty, p in frames),
    "no CRC garbage": len(frames) > 0 and sum(8 + len(p) for _, _, p in frames) == len(data),
    "OSD final page drawn": "Channel" in osd or "Wiring" in osd,
}
ok = True
for k, v in checks.items():
    print(f"{'PASS' if v else 'FAIL'}  {k}")
    ok &= v
sys.exit(0 if ok else 1)
