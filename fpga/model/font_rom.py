#!/usr/bin/env python3
"""Build rtl/osd/font.hex (128 glyphs x 16 rows, one byte per row, MSB = leftmost pixel).

0x20..0x7E: Spleen 8x16 (third_party/spleen, BSD-2-Clause).
0x01..0x08: bar-graph cells, k = 1..8 leftmost columns filled (RSSI / level bars).
0x09      : empty bar cell with a baseline, 0x0A: right-pointing cursor triangle.
Other codes are blank.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
rom = [[0] * 16 for _ in range(128)]

enc = None
rows = []
in_bitmap = False
for line in (ROOT / "third_party/spleen/spleen-8x16.bdf").read_text().splitlines():
    if line.startswith("ENCODING"):
        enc = int(line.split()[1])
    elif line == "BITMAP":
        in_bitmap, rows = True, []
    elif line == "ENDCHAR":
        if enc is not None and 0x20 <= enc <= 0x7E:
            rom[enc] = [int(r, 16) for r in rows] + [0] * (16 - len(rows))
        in_bitmap = False
    elif in_bitmap:
        rows.append(line.strip())

for k in range(1, 9):
    fill = (0xFF << (8 - k)) & 0xFF
    rom[k] = [0, 0] + [fill] * 12 + [0, 0]
rom[9] = [0] * 13 + [0xFF] + [0, 0]
rom[10] = [0, 0, 0x80, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC, 0xF8, 0xF0, 0xE0, 0xC0, 0x80, 0, 0, 0]

out = ROOT / "rtl/osd/font.hex"
out.write_text("".join(f"{b:02x}\n" for g in rom for b in g))
print(f"{out}: {len(rom)} glyphs")
