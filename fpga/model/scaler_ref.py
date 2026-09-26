#!/usr/bin/env python3
"""Bit-exact host model of rtl/out/out_path.v (deinterlace + 4-tap polyphase scaler + RGB).

Fields are arrays of shape (L, 360) of 32-bit words {Cr, Y1, Cb, Y0} (fb_format layout).
render(top, bottom, newest_odd, pal, weave, aspect_169) returns a (720, 1280, 3) uint8 frame
exactly as the RTL emits it (black pillarbox bars in 4:3 mode).

  python3 model/scaler_ref.py pattern OUT.hex                    test fields for sim/tb_scaler.v
  python3 model/scaler_ref.py compare OUT.hex RTL.txt PNG_PREFIX pal weave aspect newest_odd
"""
import sys

import numpy as np

from scaler_coef import TABLE, TABLE_BS

COEF = np.array(TABLE, dtype=np.int64)          # (32, 4) luma: Catmull-Rom
COEFC = np.array(TABLE_BS, dtype=np.int64)      # chroma: cubic B-spline


def clip7(s):
    r = (s + 64) >> 7
    return np.clip(r, 0, 255)


def unpack(field):
    f = field.astype(np.int64)
    y = np.empty((f.shape[0], 720), np.int64)
    c = np.empty((f.shape[0], 720), np.int64)   # co-sited component per pixel: Cb (even), Cr (odd)
    y[:, 0::2] = f & 0xFF
    y[:, 1::2] = (f >> 16) & 0xFF
    c[:, 0::2] = (f >> 8) & 0xFF
    c[:, 1::2] = (f >> 24) & 0xFF
    return y, c


def vertical_params(pal: bool, weave: bool, newest_odd: bool):
    if weave:
        S = 52429 if pal else 43691
        P0 = -6554 if pal else -10923
    else:
        S = 26214 if pal else 21845
        P0 = (-3277 if newest_odd else -36045) if pal else (-5461 if newest_odd else -38229)
    return S, P0


def render(top, bottom, newest_odd, pal, weave, aspect_169):
    L = 288 if pal else 240
    S, P0 = vertical_params(pal, weave, newest_odd)
    kmax = 2 * L - 1 if weave else L - 1
    newest = top if newest_odd else bottom
    ty, tc = unpack(top)
    by, bc = unpack(bottom)
    ny, nc = unpack(newest)

    def src(key):
        if weave:                                 # frame line q: even -> top field
            return (ty[key >> 1], tc[key >> 1]) if (key & 1) == 0 else (by[key >> 1], bc[key >> 1])
        return ny[key], nc[key]

    W = 1280 if aspect_169 else 960
    xs = 0 if aspect_169 else 160
    Sh = 36864 if aspect_169 else 49152
    U0 = -14336 if aspect_169 else -8192
    x = np.arange(W, dtype=np.int64)
    acc = U0 + x * Sh
    n = acc >> 16
    ph = (acc >> 11) & 31
    accc = acc >> 1
    m = accc >> 16
    phc = (accc >> 11) & 31
    out = np.zeros((720, 1280, 3), np.uint8)
    for yo in range(720):
        pos = P0 + yo * S
        k = pos >> 16
        vph = (pos >> 11) & 31
        keys = [min(max(k - 1 + j, 0), kmax) for j in range(4)]
        taps = [src(q) for q in keys]
        vy = clip7(sum(COEF[vph, j] * taps[j][0] for j in range(4)))
        vcv = clip7(sum(COEFC[vph, j] * taps[j][1] for j in range(4)))
        ypad = np.concatenate([[vy[0], vy[0]], vy, [vy[719], vy[719]]])       # index p + 2
        cb = vcv[0::2]
        cr = vcv[1::2]
        cbp = np.concatenate([[cb[0], cb[0]], cb, [cb[359], cb[359]]])
        crp = np.concatenate([[cr[0], cr[0]], cr, [cr[359], cr[359]]])
        Y = clip7(sum(COEF[ph, j] * ypad[n - 1 + j + 2] for j in range(4)))
        Cb = clip7(sum(COEFC[phc, j] * cbp[m - 1 + j + 2] for j in range(4)))
        Cr = clip7(sum(COEFC[phc, j] * crp[m - 1 + j + 2] for j in range(4)))
        yy = (Y - 16) * 1192
        r = np.clip((yy + (Cr - 128) * 1634) >> 10, 0, 255)
        g = np.clip((yy - (Cb - 128) * 401 - (Cr - 128) * 833) >> 10, 0, 255)
        b = np.clip((yy + (Cb - 128) * 2065) >> 10, 0, 255)
        out[yo, xs:xs + W] = np.stack([r, g, b], axis=1)
    return out


def test_fields():
    """Top and bottom 288-line fields (NTSC uses the first 240): 75 % bars, a luma ramp,
    one-pixel vertical lines, a diagonal and a field-dependent row marker (weave check)."""
    fields = []
    bars = [(180, 128, 128), (168, 44, 136), (145, 147, 44), (133, 63, 52),
            (63, 193, 204), (51, 109, 212), (28, 212, 120), (16, 128, 128)]  # 75 % Y'CbCr
    for parity in (0, 1):
        y = np.zeros((288, 720), np.int64)
        cb = np.zeros((288, 360), np.int64)
        cr = np.zeros((288, 360), np.int64)
        for ln in range(288):
            q = 2 * ln + parity                                   # frame line
            if q < 200:
                for i, (Y, U, V) in enumerate(bars):
                    y[ln, i * 90:(i + 1) * 90] = Y
                    cb[ln, i * 45:(i + 1) * 45] = U
                    cr[ln, i * 45:(i + 1) * 45] = V
            elif q < 330:
                y[ln] = 16 + (np.arange(720) * 219) // 719
                cb[ln] = 128
                cr[ln] = 128
            elif q < 450:
                y[ln] = np.where((np.arange(720) // 1) % 2 == 0, 235, 16) if (q // 16) % 2 else \
                    np.where((np.arange(720) // 4) % 2 == 0, 235, 16)
                cb[ln] = 128 + ((np.arange(360) * 7) % 64) - 32
                cr[ln] = 128
            else:
                d = (np.arange(720) + 3 * q) % 96
                y[ln] = np.where(d < 8, 235, 40 + 60 * parity)
                cb[ln] = 90
                cr[ln] = 170
        words = (cr << 24) | (y[:, 1::2] << 16) | (cb << 8) | y[:, 0::2]
        fields.append(words.astype(np.uint32))
    return fields


def main():
    if sys.argv[1] == "pattern":
        top, bottom = test_fields()
        with open(sys.argv[2], "w") as f:
            for fld in (top, bottom):
                for w in fld.reshape(-1):
                    f.write(f"{int(w):08x}\n")
    elif sys.argv[1] == "compare":
        _, _, hexf, rtlf, png = sys.argv[:5]
        pal, weave, aspect, newest_odd = (int(a) for a in sys.argv[5:9])
        top, bottom = test_fields()
        L = 288 if pal else 240
        ref = render(top[:L], bottom[:L], bool(newest_odd), bool(pal), bool(weave), bool(aspect))
        rtl = np.loadtxt(rtlf, dtype=np.int64, converters={0: lambda s: int(s, 16)}).reshape(720, 1280)
        rtl = np.stack([(rtl >> 16) & 255, (rtl >> 8) & 255, rtl & 255], axis=2).astype(np.uint8)
        diff = np.any(rtl != ref, axis=2)
        try:
            from PIL import Image
            Image.fromarray(rtl).save(png + "_rtl.png")
            Image.fromarray(ref).save(png + "_ref.png")
        except ImportError:
            pass
        bad = int(diff.sum())
        where = "" if not bad else f", first at (y, x) = {tuple(int(v) for v in np.argwhere(diff)[0])}"
        print(f"{rtlf}: {720 * 1280 - bad}/{720 * 1280} pixels match{where} {'PASS' if bad == 0 else 'FAIL'}")
        sys.exit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()
