#!/usr/bin/env python3
"""Host reference for the full receive chain after video_timing (sim/tb_full.v).

  python3 model/chain_ref.py CV_DUMP RTL_FRAME META_LOG PNG_PREFIX

CV_DUMP: "x cv line_no field_odd" per 1280-grid sample from the RTL video_timing (the sync /
level / resampler stage has no separate host model; everything after it does):
  chroma_ref.chroma_decode (bit-exact with chroma_dec.v) -> fb_format_ref (bit-exact with
  fb_format.v, below) -> fields -> scaler_ref.render (bit-exact with out_path.v).
The RTL frame must match bit-exact. The 75 % bar colours are also measured against their
nominal RGB (a sanity check of the whole chain, including the RF model and video_timing).
"""
import sys

import numpy as np

from chroma_ref import chroma_decode
from scaler_ref import render


def wrap(v: int, bits: int) -> int:
    m = 1 << bits
    v &= m - 1
    return v - m if v >= m >> 1 else v


def fb_format_line(Y, U, V, pal: bool, brightness: int = 0, contrast: int = 128):
    """One active line -> 360 words {Cr, Y1, Cb, Y0}, as fb_format.v."""
    x0, step = (193, 97090) if pal else (179, 97767)
    yblack, kY, kCb, kCr = (0, 320, 251, 178) if pal else (56, 323, 253, 180)
    spos, px, y_p = x0 << 16, 0, 0
    words, y0_q, cb_q = [], 0, 0
    for x in range(1280):
        y_in, u_in, v_in = int(Y[x]), int(U[x]), int(V[x])
        if x != 0 and px < 720 and x == ((spos >> 16) & 0x7FF) + 1:
            fr = spos & 0xFFFF
            yi = wrap((y_p << 16) + (y_in - y_p) * fr, 28)
            y_int = wrap(yi >> 16, 12)
            ys = (y_int - yblack) * kY
            yc = ((ys >> 10) * contrast) >> 7
            yv = yc + 16 + brightness
            y8 = min(max(yv, 0), 255)
            cbv = ((u_in * kCb) >> 10) + 128
            crv = ((v_in * kCr) >> 10) + 128
            cb8 = min(max(cbv, 16), 240)
            cr8 = min(max(crv, 16), 240)
            if px % 2 == 0:
                y0_q, cb_q = y8, cb8
            else:
                words.append((cr8 << 24) | (y8 << 16) | (cb_q << 8) | y0_q)
            px += 1
            spos += step
        y_p = y_in
    return words


def fields_from_dump(path: str, pal: bool):
    rows = np.loadtxt(path, dtype=np.int64)
    starts = np.where(rows[:, 0] == 0)[0]
    lines, tags, ff = [], [], []
    for a in starts:
        if a + 1280 <= len(rows) and (rows[a:a + 1280, 0] == np.arange(1280)).all():
            lines.append(rows[a:a + 1280, 1])
            tags.append((int(rows[a, 2]), int(rows[a, 3])))
            # video_timing feed-forward (pal, ntsc) on the x = 1279 row, when the dump has it
            ff.append((int(rows[a + 1279, 4]), int(rows[a + 1279, 5])) if rows.shape[1] >= 6 else (0, 0))
    dec = chroma_decode(lines, is_pal=pal, comb=True, ff=ff)
    first, n = (22, 288) if pal else (17, 240)
    fields = []                                   # [(odd, {line: words})]
    for (Yl, Ul, Vl), (line_no, odd) in zip(dec, tags):
        if line_no == first:
            fields.append((odd, {}))
        if fields and first <= line_no < first + n:
            fields[-1][1][line_no - first] = fb_format_line(Yl, Ul, Vl, pal)
    out = []
    for odd, d in fields:
        arr = np.zeros((n, 360), np.uint32)
        for k, w in d.items():
            arr[k, :len(w)] = w
        out.append((odd, arr, len(d)))
    return out


BARS = {  # 75 % bars, full-range RGB after BT.601 limited -> full conversion (nominal)
    "white": (191, 191, 191), "yellow": (191, 191, 0), "cyan": (0, 191, 191), "green": (0, 191, 0),
    "magenta": (191, 0, 191), "red": (191, 0, 0), "blue": (0, 0, 191), "black": (0, 0, 0),
}


def main():
    cv, rtlf, meta, png = sys.argv[1:5]
    line = next(l for l in open(meta) if l.startswith("META"))
    m = dict(kv.split("=") for kv in line.split()[1:])
    pal, weave, aspect = int(m["pal"]), int(m["weave"]), int(m["aspect"])
    F, F2, newest_odd = int(m["field"]), int(m["prev"]), int(m["odd"])
    fields = fields_from_dump(cv, bool(pal))
    print(f"reference: {len(fields)} fields in the cv dump; RTL shows field {F} (prev {F2}), odd={newest_odd}")
    odd, fa, nl = fields[F - 1]
    print(f"field {F}: odd={odd}, {nl} active lines")
    if weave:
        _, fb, _ = fields[F2 - 1]
        top, bottom = (fa, fb) if newest_odd else (fb, fa)
    else:
        top = bottom = fa
    ref = render(top, bottom, bool(newest_odd), bool(pal), bool(weave), bool(aspect))
    rtl = np.loadtxt(rtlf, dtype=np.int64, converters={0: lambda s: int(s, 16)}).reshape(720, 1280)
    rtl = np.stack([(rtl >> 16) & 255, (rtl >> 8) & 255, rtl & 255], axis=2).astype(np.uint8)
    from PIL import Image
    Image.fromarray(rtl).save(png + "_rtl.png")
    Image.fromarray(ref).save(png + "_ref.png")
    diff = np.any(rtl != ref, axis=2)
    bad = int(diff.sum())
    # bar colours: middle of each of iqsynth's 8 equal bars (its active window is close to,
    # not exactly, the 720-sample BT.601 window, so this is informative, not a pass/fail)
    x0 = 0 if aspect else 160
    W = 1280 if aspect else 960
    worst = 0
    for i, (name, rgb) in enumerate(BARS.items()):
        xc = x0 + int((i + 0.5) * W / 8)
        patch = rtl[250:330, xc - 10:xc + 10].reshape(-1, 3).astype(int).mean(axis=0)
        err = max(abs(patch - np.array(rgb)))
        worst = max(worst, err)
        print(f"  bar {name:8s} RGB {tuple(int(v) for v in patch)} nominal {rgb} max error {err:.0f}")
    ok = bad == 0
    print(f"{rtlf}: {720 * 1280 - bad}/{720 * 1280} pixels match the host reference "
          f"{'PASS' if ok else 'FAIL'}; worst bar error {worst:.0f} codes (informative)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
