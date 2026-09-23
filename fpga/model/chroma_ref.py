#!/usr/bin/env python3
"""Bit-exact integer reference of fpga/rtl/dsp/chroma_dec.v (THEORY §11).

Input : line-locked composite (mV) on a 1280-point grid (video_timing.v output).
Output: per sample Y (mV), U, V (mV scale) after Y/C separation and demodulation.

Subcarrier NCO (16-bit phase, 1/65536 turn), exact on the 1280 grid:
  NTSC 227.5 cycles/line -> 91/512 turn/sample  = 11648   (+180 deg per line)
  PAL  283.75 cycles/line -> 227/1024 turn/sample = 14528 (+270 deg per line)
Burst loop: per line, phase error from the burst's cos-product (NTSC: that line;
PAL: sum of two lines so the +-45 deg V swing cancels); proportional correction.
"""
from __future__ import annotations

import math

import numpy as np

LS = 1280
INC = {False: 11648, True: 14528}          # is_pal -> NCO increment
BURST_X0, BURST_X1 = 112, 144              # 32 samples inside the burst (both standards)
LOOP_SHIFT = 9                             # phase correction = -(err >> LOOP_SHIFT)
KILL_BU = 60000                            # |burst U product| below this -> colour killer
KILL_LINES = 8


def sincos_lut():
    s = [int(round(511 * math.sin(2 * math.pi * k / 256))) for k in range(256)]
    c = [int(round(511 * math.cos(2 * math.pi * k / 256))) for k in range(256)]
    return s, c


class Boxcar:
    def __init__(self, n):
        self.n, self.buf, self.acc = n, [0] * n, 0

    def push(self, x):
        self.acc += x - self.buf[-1]
        self.buf = [x] + self.buf[:-1]
        return self.acc


X_ACT0 = 160                               # U/V forced to 0 before this (burst/blanking)
SAT_DEFAULT = 146                          # compensates the ~12 % chroma roll-off (fpga/README.md)


def chroma_decode(lines, is_pal: bool, comb: bool = True, hue: int = 0, sat: int = SAT_DEFAULT):
    """lines: list of 1280-sample int arrays (composite mV). Returns list of (Y, U, V) arrays.

    Streaming order (mirrored by the RTL): the burst products are complete at
    x = BURST_X1, where the PAL V-switch and the colour killer for this line are
    decided; the NCO correction is applied at the end of the line.
    """
    S, C = sincos_lut()
    inc = INC[is_pal]
    phi_line = 0
    prev = [np.zeros(LS, dtype=np.int64), np.zeros(LS, dtype=np.int64)]   # 1H, 2H delays
    prev_u = np.zeros(LS, dtype=np.int64)
    prev_v = np.zeros(LS, dtype=np.int64)
    bv_prev = 0
    kill_cnt = 0
    out = []
    # the notch sees the continuous stream (x-2 / x+2 cross line boundaries), zero before the start
    flat = np.concatenate([np.zeros(2, dtype=np.int64)] + [np.asarray(l, dtype=np.int64) for l in lines]
                          + [np.zeros(2, dtype=np.int64)])
    for li, cv in enumerate(lines):
        cv = np.asarray(cv, dtype=np.int64)
        dly = prev[1] if is_pal else prev[0]
        # burst products (x in [BURST_X0, BURST_X1))
        bu = bv = 0
        for x in range(BURST_X0, BURST_X1):
            k = ((phi_line + x * inc) & 0xFFFF) >> 8
            bu += int(cv[x]) * S[k]
            bv += int(cv[x]) * C[k]
        sw = -1 if (is_pal and bv < 0) else 1
        kill_cnt = min(kill_cnt + 1, KILL_LINES) if abs(bu) < KILL_BU else max(kill_cnt - 1, 0)
        killed = kill_cnt >= KILL_LINES
        u1, u2, v1, v2 = Boxcar(8), Boxcar(6), Boxcar(8), Boxcar(6)
        Y = np.zeros(LS, dtype=np.int64)
        U = np.zeros(LS, dtype=np.int64)
        V = np.zeros(LS, dtype=np.int64)
        for x in range(LS):
            phi = (phi_line + x * inc) & 0xFFFF
            if comb:
                ch = (int(cv[x]) - int(dly[x])) >> 1
            else:
                g = 2 + li * LS + x
                ch = (2 * int(flat[g]) - int(flat[g - 2]) - int(flat[g + 2])) >> 2
            Y[x] = int(cv[x]) - ch
            kd = ((phi + hue) & 0xFFFF) >> 8
            u = u2.push(u1.push(ch * S[kd]))       # boxcar gain 48
            v = v2.push(v1.push(ch * C[kd]))
            uo = (u * sat) >> 20                   # 511/2*48*128/2^20 = 1.497 per mV of U
            vo = ((v * sat) >> 20) * sw
            if x < X_ACT0 or killed:
                uo = vo = 0
            if is_pal:                             # PAL-D delay-line average
                U[x] = (uo + int(prev_u[x])) >> 1
                V[x] = (vo + int(prev_v[x])) >> 1
                prev_u[x], prev_v[x] = uo, vo
            else:
                U[x], V[x] = uo, vo
        err = (bv + bv_prev) if is_pal else bv
        bv_prev = bv
        corr = -(err >> LOOP_SHIFT)
        if bu > 0:
            corr += 32768                          # locked 180 deg off: flip
        phi_line = (phi_line + LS * inc + corr) & 0xFFFF
        prev = [cv, prev[0]]
        out.append((Y, U, V))
    return out


def write_sincos(outdir) -> None:
    S, C = sincos_lut()
    for name, t in (("sin_lut.hex", S), ("cos_lut.hex", C)):
        with open(f"{outdir}/{name}", "w") as f:
            f.write("\n".join(f"{v & 0x3FF:03x}" for v in t) + "\n")


if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 3 and sys.argv[1] == "luts":
        write_sincos(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "decode":
        # decode <cv dump from tb_chain_a> <out> [pal] [notch]
        rows = np.loadtxt(sys.argv[2], dtype=int)
        starts = np.where(rows[:, 0] == 0)[0]
        lines = [rows[a:a + LS, 1] for a in starts
                 if a + LS <= len(rows) and (rows[a:a + LS, 0] == np.arange(LS)).all()]
        res = chroma_decode(lines, is_pal="pal" in sys.argv[4:], comb="notch" not in sys.argv[4:])
        with open(sys.argv[3], "w") as f:
            for Y, U, V in res:
                for x in range(LS):
                    f.write(f"{x} {Y[x]} {U[x]} {V[x]}\n")
        print(f"decoded {len(res)} lines")
