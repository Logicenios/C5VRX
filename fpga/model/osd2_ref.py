#!/usr/bin/env python3
"""Model of the proposed OSD v2 compositor (rtl/osd, menu redesign) and a mock-up renderer.

Layers, back to front, all alphas 0..16 and scaled by a global fade (0..16):
  video -> panel (rounded rectangle, palette colour) -> bar (rounded rectangle: the animated menu
  cursor) -> text (40 x 16 cells of 8 x 16 glyphs, Scale2x-smoothed to 16 x 32, palette colour
  per cell; attr bit 4 = dim text).
Blend per channel: out = (v * (16 - a) + c * a) >> 4. Rounded corners: pixel centres with
d^2 < r^2 are inside, r^2 <= d^2 < (r + 1)^2 get half alpha (one-pixel anti-aliased edge).
Everything here is integer arithmetic a small pipeline can do (no multipliers wider than 8 x 5).

  python3 model/osd2_ref.py mock OUTDIR BACKGROUND.jpg     # mock-up stills + animation frames
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
W, H = 1280, 720
COLS, ROWS, CW, CH = 40, 16, 16, 32

# ------------------------------------------------------------------ font: Spleen 8x16 + icons
def load_font():
    """rtl/osd/font.hex (model/font_rom.py): the same bytes the RTL reads"""
    b = [int(l, 16) for l in (ROOT / "rtl/osd/font.hex").read_text().split()]
    return [b[16 * c:16 * c + 16] for c in range(128)]


FONT = load_font()


def glyph_scale2x(rows):
    """8x16 glyph -> 16x32 with Scale2x (EPX), neighbours outside the glyph = 0 (per-cell, as the
    hardware sees only the current cell's rows)."""
    g = np.array([[(r >> (7 - x)) & 1 for x in range(8)] for r in rows], dtype=np.uint8)
    p = np.pad(g, 1)
    out = np.zeros((32, 16), np.uint8)
    for y in range(16):
        for x in range(8):
            E = p[y + 1, x + 1]; B = p[y, x + 1]; D = p[y + 1, x]; F = p[y + 1, x + 2]; Hh = p[y + 2, x + 1]
            if B != Hh and D != F:
                e0 = D if D == B else E; e1 = F if B == F else E
                e2 = D if D == Hh else E; e3 = F if Hh == F else E
            else:
                e0 = e1 = e2 = e3 = E
            out[2 * y, 2 * x], out[2 * y, 2 * x + 1], out[2 * y + 1, 2 * x], out[2 * y + 1, 2 * x + 1] = e0, e1, e2, e3
    return out


GLYPH2X = [glyph_scale2x(FONT[c]) for c in range(128)]
GLYPH_PLAIN = [np.kron(np.array([[(r >> (7 - x)) & 1 for x in range(8)] for r in FONT[c]], np.uint8),
                       np.ones((2, 2), np.uint8)) for c in range(128)]

# ------------------------------------------------------------------ palette (CPU writable)
PALETTE = [
    (0x0E, 0x12, 0x18),  # 0 panel
    (0xF2, 0xF4, 0xF6),  # 1 text
    (0x8E, 0x98, 0xA4),  # 2 secondary text
    (0x2B, 0xC4, 0xB6),  # 3 accent (teal)
    (0x0A, 0x0E, 0x12),  # 4 text on accent
    (0x3C, 0xDC, 0x78),  # 5 green
    (0xF5, 0xC5, 0x42),  # 6 yellow
    (0xF0, 0x55, 0x55),  # 7 red
    (0x5A, 0x64, 0x70),  # 8 divider
    (0x1E, 0x28, 0x34),  # 9 panel light
] + [(0, 0, 0)] * 6


def rounded_alpha(w, h, r, a):
    """alpha map (0..16) of a w x h rounded rectangle, as rtl/osd/osd2.v: in a corner square
    (side r) d^2 = cx^2 + cy^2 < r^2 -> a, < (r + 1)^2 -> a >> 1, else 0"""
    m = np.full((h, w), a, np.int32)
    if r <= 0 or w <= 0 or h <= 0:
        return m
    ys, xs = np.mgrid[0:h, 0:w]
    cx = np.where(xs < r, r - 1 - xs, np.where(xs >= w - r, xs - (w - r), -1))
    cy = np.where(ys < r, r - 1 - ys, np.where(ys >= h - r, ys - (h - r), -1))
    corner = (cx >= 0) & (cy >= 0)
    d2 = cx * cx + cy * cy
    m[corner & (d2 >= r * r)] = a >> 1
    m[corner & (d2 >= (r + 1) * (r + 1))] = 0
    return m


def mix(v, c, a):
    """out = v + (((c - v) * a) >> 4), per channel, a = 0..16 (arrays)"""
    return v + (((c - v) * a) >> 4)


def render(video, pal, layers, tx0, ty0, ta, tda, text, smooth=True):
    """Bit-exact model of osd2.v. video: H x W x 3 ints; pal: 16 RGB tuples; layers: 3 x
    (x, y, w, h, r, colour index, alpha); text: 1024 words {attr, char}, index row * 64 + col."""
    out = video.astype(np.int64).copy()
    for (x, y, w, h, r, ci, a) in layers:
        am = np.zeros((H, W), np.int64)
        m = rounded_alpha(w, h, r, a)
        x1, y1 = min(x + w, W), min(y + h, H)
        if x < W and y < H and w > 0 and h > 0:
            am[y:y1, x:x1] = m[:y1 - y, :x1 - x]
        c = np.array(pal[ci], np.int64)
        out = mix(out, c[None, None, :], am[..., None])
    # text layer: alpha and colour per pixel
    ta_m = np.zeros((H, W), np.int64); tc = np.zeros((H, W, 3), np.int64)
    gl = GLYPH2X if smooth else GLYPH_PLAIN
    for row in range(ROWS):
        for col in range(COLS):
            wd = text[row * 64 + col]
            ch, attr = wd & 0x7F, (wd >> 8) & 0x1F
            px, py = tx0 + col * CW, ty0 + row * CH
            if px >= W or py >= H:
                continue
            g = gl[ch].astype(bool)[:H - py, :W - px]
            reg = ta_m[py:py + CH, px:px + CW]
            reg[g] = tda if attr & 0x10 else ta
            tc[py:py + CH, px:px + CW][g] = pal[attr & 15]
    return np.clip(mix(out, tc, ta_m[..., None]), 0, 255)


# ------------------------------------------------------------------ the menu screen (firmware layout)
ITEMS = [(0x02, "Channel", "A1  5865 MHz"), (0x05, "Scan", "Start"), (0x04, "Standard", "Auto"),
         (0x04, "Output rate", "Auto 50/59.94"), (0x04, "Aspect", "4:3"), (0x04, "Deinterlace", "Bob"),
         (0x03, "Brightness", "0"), (0x03, "Contrast", "100 %"), (0x03, "Saturation", "100 %"),
         (0x03, "Hue (NTSC)", "0 deg"), (0x03, "Y/C filter", "Comb"), (0x03, "De-emphasis", "4 dB"),
         (0x03, "Noise filter", "5.3 MHz"), (0x03, "Signal loss", "Last frame"), (0x04, "Test pattern", "Off"),
         (0x03, "Decoder", "Run"), (0x0B, "Link status", "wiring OK"), (0x0C, "Save", ""), (0x07, "Exit", "")]


def put(cells, row, col, text, fg=1, attr=0):
    for i, ch in enumerate(text):
        if 0 <= col + i < COLS:
            cells[(row, col + i)] = (ord(ch) if isinstance(ch, str) else ch, fg, attr)


def menu_state(cursor=0, bar_y=None, edit=False, x0=320, y0=104, fade=16, first=0):
    cells = {}
    # header: name in accent, channel, signal bars
    put(cells, 0, 2, "C5VRX", 3)
    put(cells, 0, 23, "A1 5865 MHz", 1); put(cells, 0, 37, [0x0B], 5)
    put(cells, 1, 2, [0x0F] * 36, 8)
    vis = ITEMS[first:first + 12]
    for i, (_, label, val) in enumerate(vis):
        r = 2 + i; it = first + i; cur = it == cursor
        put(cells, r, 3, label, 1 if cur else 1)
        if val:
            if cur and edit:
                put(cells, r, 37 - len(val) - 2, [0x0C], 3); put(cells, r, 37 - len(val), val, 1); put(cells, r, 38, [0x0D], 3)
            else:
                put(cells, r, 38 - len(val), val, 1 if cur else 2)
    put(cells, 14, 2, [0x0F] * 36, 8)
    # footer: live status left, hints right
    put(cells, 15, 2, [0x0E], 5); put(cells, 15, 4, "PAL  720p50", 2)
    put(cells, 15, 24, "hold: select", 2, 0x10)
    by = y0 + (2 + cursor - first) * CH if bar_y is None else bar_y
    return dict(x0=x0, y0=y0, fade=fade, cells=cells,
                panel=(x0, y0 - 10, 640, 532, 24, 0, 14),
                bar=(x0 + 16, by + 1, 608, 30, 10, 3, 9 if edit else 5),
                panel2=(x0 + 16, by + 5, 5, 22, 2, 3, 16))


def composite(video, st):
    """mock-up state (menu_state) -> render(): fade scales every alpha as the firmware will"""
    f = st.get("fade", 16)
    layers = [(*st[k][:6], (st[k][6] * f) >> 4) for k in ("panel", "bar", "panel2")]
    text = [0x20] * 1024
    for (row, col), (ch, fg, attr) in st["cells"].items():
        text[row * 64 + col] = ((fg | (attr & 0x10)) << 8) | (ch & 0x7F)
    out = render(video, PALETTE, layers, st["x0"], st["y0"], (16 * f) >> 4, (10 * f) >> 4, text, st.get("smooth", True))
    return out.astype(np.uint8)


def ease_out(t):                               # cubic ease-out, t in 0..1 (firmware: 16-entry table)
    return 1 - (1 - t) ** 3


def main():
    from PIL import Image
    outdir = Path(sys.argv[2]); outdir.mkdir(parents=True, exist_ok=True)
    bg = np.array(Image.open(sys.argv[3]).convert("RGB").resize((W, H), Image.BILINEAR))
    frames = []
    # 1. open: slide in from the right and fade in, 10 frames
    for k in range(11):
        e = ease_out(k / 10)
        st = menu_state(cursor=0, x0=320 + int(round(48 * (1 - e))), fade=int(round(16 * e)))
        frames.append(composite(bg, st))
    for _ in range(8): frames.append(frames[-1])
    # 2. cursor moves down 0 -> 3 (each move: 6 frames ease-out)
    for c in range(3):
        y_from, y_to = 104 + (2 + c) * CH, 104 + (3 + c) * CH
        for k in range(1, 7):
            e = ease_out(k / 6)
            frames.append(composite(bg, menu_state(cursor=c + 1, bar_y=int(round(y_from + (y_to - y_from) * e)))))
        for _ in range(4): frames.append(frames[-1])
    # 3. edit mode on "Output rate"
    for _ in range(14): frames.append(composite(bg, menu_state(cursor=3, edit=True)))
    # 4. close: fade out, 6 frames
    for k in range(6, -1, -1):
        e = k / 6
        frames.append(composite(bg, menu_state(cursor=3, fade=int(round(16 * e)))))
    for _ in range(6): frames.append(frames[-1])
    imgs = [Image.fromarray(f).resize((960, 540), Image.LANCZOS) for f in frames]
    imgs[0].save(outdir / "menu_animation.gif", save_all=True, append_images=imgs[1:], duration=33, loop=0, optimize=True)
    # stills: new menu, edit mode, plain vs smoothed text
    Image.fromarray(composite(bg, menu_state(cursor=3))).save(outdir / "menu_new.png")
    Image.fromarray(composite(bg, menu_state(cursor=3, edit=True))).save(outdir / "menu_edit.png")
    st = menu_state(cursor=3); st["smooth"] = False
    Image.fromarray(composite(bg, st)).save(outdir / "menu_new_unsmoothed.png")
    print(f"{len(frames)} animation frames -> {outdir}/menu_animation.gif; stills in {outdir}")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "mock":
        main()


# ------------------------------------------------------------------ testbench vectors (sim/tb_osd2.v)
def video_pattern():
    """the tb's rgb_in for active pixel (hc, vc)"""
    hc, vc = np.meshgrid(np.arange(W), np.arange(H))
    return np.stack([(hc * 5 + vc * 3) & 255, (hc ^ (vc << 1)) & 255, ((hc + vc * 7) >> 2) & 255], axis=-1)


def tbgen(outdir, seed):
    rng = np.random.default_rng(seed)
    pal = [tuple(int(v) for v in rng.integers(0, 256, 3)) for _ in range(16)]
    layers = []
    for _ in range(3):
        r = int(rng.integers(0, 32))
        w, h = int(rng.integers(2 * r + 1, 700)), int(rng.integers(2 * r + 1, 400))
        layers.append((int(rng.integers(0, 1100)), int(rng.integers(0, 600)), w, h, r,
                       int(rng.integers(0, 16)), int(rng.integers(0, 17))))
    if seed == 4:                               # edges: layers at x = 0, on row 0 (after the frame
        layers = [(0, 0, 300, 200, 0, 1, 16),   # wrap, square: pixel 0 of each line drawn) and on the
                  (980, 20, 300, 200, 31, 2, 16), (0, 690, 1280, 30, 12, 3, 9)]   # last rows, r > 16
    tx0, ty0 = int(rng.integers(0, 800)), int(rng.integers(0, 300))
    ta, tda = int(rng.integers(8, 17)), int(rng.integers(0, 17))
    text = [int(rng.integers(0, 32)) << 8 | int(rng.integers(0, 128)) for _ in range(1024)]
    regs = [0] * 32
    for i in range(16):
        regs[i] = pal[i][0] << 16 | pal[i][1] << 8 | pal[i][2]
    for k, (x, y, w, h, r, ci, a) in enumerate(layers):
        regs[16 + 3 * k] = y << 16 | x; regs[17 + 3 * k] = h << 16 | w; regs[18 + 3 * k] = a << 16 | ci << 8 | r
        regs[27 + k] = (r + 1) * (r + 1) << 16 | r * r
    regs[25] = ty0 << 16 | tx0; regs[26] = tda << 8 | ta
    out = Path(outdir)
    (out / "osd2_regs.hex").write_text("".join(f"{v:08x}\n" for v in regs))
    (out / "osd2_text.hex").write_text("".join(f"{v:04x}\n" for v in text))
    img = render(video_pattern(), pal, layers, tx0, ty0, ta, tda, text)
    (out / "osd2_ref.txt").write_text("".join(f"{int(p[0]):02x}{int(p[1]):02x}{int(p[2]):02x}\n" for p in img.reshape(-1, 3)))
    print(f"tbgen seed {seed}: layers {layers}, text at ({tx0}, {ty0}) alpha {ta}/{tda}")


if __name__ == "__main__" and len(sys.argv) >= 4 and sys.argv[1] == "tbgen":
    tbgen(sys.argv[2], int(sys.argv[3]))
