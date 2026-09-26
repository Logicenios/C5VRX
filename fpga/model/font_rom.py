#!/usr/bin/env python3
"""Build rtl/osd/font.hex (128 glyphs x 16 rows, one byte per row, MSB = leftmost pixel).

0x20..0x7E: Spleen 8x16 (third_party/spleen, BSD-2-Clause).
0x01..0x08: bar-graph cells, k = 1..8 leftmost columns filled (RSSI / level bars).
0x09      : empty bar cell with a baseline, 0x0A: right-pointing cursor triangle.
0x0B..0x10: OSD v2 icons (signal bars, edit arrows, status dot, divider, antenna).
0x11..0x16: 4-bar signal level (two cells: bars lit in the left / right cell).
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

# OSD v2 icons (menu redesign, rtl/osd/osd2.v; model/osd2_ref.py reads font.hex)
def icon(code, art):
    rows = ["........"] * ((16 - len(art)) // 2) + art
    rows += ["........"] * (16 - len(rows))
    rom[code] = [int("".join("1" if c == "#" else "0" for c in r), 2) for r in rows]


icon(0x0B, ["......##", "......##", "....####", "....####", "..######", "..######", "########", "########",
            "########", "########"])                                                          # signal bars
icon(0x0C, [".......#", "......##", ".....###", "....####", ".....###", "......##", ".......#"])   # < (edit)
icon(0x0D, ["#.......", "##......", "###.....", "####....", "###.....", "##......", "#......."])   # > (edit)
icon(0x0E, ["..####..", ".######.", "########", "########", "########", ".######.", "..####.."])   # status dot
rom[0x0F] = [0] * 8 + [0xFF] + [0] * 7                                                         # divider
icon(0x10, ["...##...", "..####..", ".##..##.", "##....##", "#..##..#", "..#..#..", ".#....#.",
            "...##...", "...##...", "...##..."])                                              # antenna

# signal level, 4 bars over two cells (bars 1-2 in 0x11..0x13, bars 3-4 in 0x14..0x16), each bar 3
# px wide: lit = solid, unlit = outline (one colour per cell). Glyph index = bars lit in that cell.
def bars_cell(heights, lit):
    rows = [[0] * 8 for _ in range(16)]
    for b, (h, on) in enumerate(zip(heights, lit)):
        x0 = 1 + b * 4
        for y in range(15 - h, 15):
            for x in range(x0, x0 + 3):
                edge = y == 15 - h or y == 14 or x == x0 or x == x0 + 2
                if on or edge:
                    rows[y][x] = 1
    return [int("".join(map(str, r)), 2) for r in rows]


for k in range(3):
    rom[0x11 + k] = bars_cell((5, 8), (k >= 1, k >= 2))
    rom[0x14 + k] = bars_cell((11, 14), (k >= 1, k >= 2))

out = ROOT / "rtl/osd/font.hex"
out.write_text("".join(f"{b:02x}\n" for g in rom for b in g))
print(f"{out}: {len(rom)} glyphs")
