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
LOCK_GATE = 150000     # |bu| + |bv| below this: no burst on the line, hold the loop (~15 % of nominal)
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
# ACC (automatic colour gain): the burst magnitude (max + 3/8 min of |bu|, |bv|) is filtered over
# lines (1/64 per line, lines with a burst and no colour killer) and the saturation of the next
# line is sat * g / 256 with g = ACC_REF * 256 / filtered, clamped to 0.5 .. 4. ACC_REF is the
# median magnitude of a standard synthetic signal (model/iqsynth.py: burst = sync amplitude)
# through the chain (sim/data/chroma_in*.txt), so a standard signal decodes with g = 1 and sat
# keeps its meaning (146 = nominal, which already covers the resampler's roll-off at fsc).
ACC_REF = {True: 1003168, False: 1125856}   # is_pal ->
ACC_SHIFT = 6
ACC_GMIN, ACC_GMAX = 128, 1023
SAT_DEFAULT = 146                          # compensates the ~12 % chroma roll-off (fpga/README.md)


def sat16(v: int) -> int:
    """chroma_dec log value: v >> 8 saturated to signed 16 bits, as an unsigned 16-bit field"""
    return max(-32768, min(32767, v >> 8)) & 0xFFFF


def acc_gain(mf: int, is_pal: bool) -> int:
    return max(ACC_GMIN, min(ACC_GMAX, (ACC_REF[is_pal] << 8) // mf))


def chroma_decode(lines, is_pal: bool, comb: bool = True, hue: int = 0, sat: int = SAT_DEFAULT, log=None,
                  legacy_lock: bool = False, ff=None, acc: bool = True):
    """lines: list of 1280-sample int arrays (composite mV). Returns list of (Y, U, V) arrays.

    Streaming order (mirrored by the RTL): the burst products are complete at
    x = BURST_X1, where the PAL V-switch and the colour killer for this line are
    decided; the NCO correction is applied at the end of the line.
    log: optional list; one colour-lock record per line is appended, as chroma_dec.v's log_* outputs
    (bu, bv, corr, flags {flip, V switch, killed}).
    Burst lock (MEASUREMENTS M79): the 180-degree flip is decided on the two-line sum of burst U, in
    which the PAL +-45 degree swing cancels, with the previous line's values carried into the
    flipped reference frame; lines without a burst (|bu| + |bv| < LOCK_GATE) hold the loop, and the
    first line with a burst again only primes the two-line sums. legacy_lock: the old rule (flip
    whenever this line's bu > 0, no gate), which can settle into a flip-every-line false lock.
    ff: optional per-line (pal, ntsc) NCO feed-forward from video_timing (cv_ff_*, the jump of the
    next line's start), added at the line end unless legacy_lock.
    """
    S, C = sincos_lut()
    inc = INC[is_pal]
    phi_line = 0
    prev = [np.zeros(LS, dtype=np.int64), np.zeros(LS, dtype=np.int64)]   # 1H, 2H delays
    prev_u = np.zeros(LS, dtype=np.int64)
    prev_v = np.zeros(LS, dtype=np.int64)
    bv_prev = 0
    bu_prev = 0
    have_prev = False
    kill_cnt = 0
    acc_mf = ACC_REF[is_pal]                   # filtered burst magnitude
    sat_eff = sat                              # this line's saturation (ACC: from the lines before)
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
            uo = (u * sat_eff) >> 20               # 511/2*48*128/2^20 = 1.497 per mV of U
            vo = ((v * sat_eff) >> 20) * sw
            if x < X_ACT0 or killed:
                uo = vo = 0
            if is_pal:                             # PAL-D delay-line average
                U[x] = (uo + int(prev_u[x])) >> 1
                V[x] = (vo + int(prev_v[x])) >> 1
                prev_u[x], prev_v[x] = uo, vo
            else:
                U[x], V[x] = uo, vo
        err = (bv + bv_prev) if is_pal else bv
        if legacy_lock:
            flip = bu > 0
            corr = -(err >> LOOP_SHIFT) + (32768 if flip else 0)
            bv_prev = bv
        else:
            present = abs(bu) + abs(bv) >= LOCK_GATE
            hold = not present or not have_prev
            flip = not hold and ((bu + bu_prev) > 0 if is_pal else bu > 0)
            corr = 0 if hold else -(err >> LOOP_SHIFT) + (32768 if flip else 0)
            if present:                            # previous line in the (possibly flipped) new frame
                bu_prev, bv_prev, have_prev = (-bu, -bv, True) if flip else (bu, bv, True)
            else:
                bu_prev, bv_prev, have_prev = 0, 0, False
        if acc:
            if abs(bu) + abs(bv) >= LOCK_GATE and not killed:
                a, b = abs(bu), abs(bv)
                mx, mn = max(a, b), min(a, b)
                acc_mf += (mx + (mn >> 2) + (mn >> 3) - acc_mf) >> ACC_SHIFT
            sat_eff = (sat * acc_gain(acc_mf, is_pal)) >> 8     # for the next line
        ffv = 0 if (legacy_lock or ff is None) else ff[li][0 if is_pal else 1]
        phi_line = (phi_line + LS * inc + corr + ffv) & 0xFFFF
        if log is not None:
            log.append((sat16(bu), sat16(bv), corr & 0xFFFF, int(flip) << 2 | (sw < 0) << 1 | int(killed)))
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
        rows = np.loadtxt(sys.argv[2], dtype=int, ndmin=2)
        starts = np.where(rows[:, 0] == 0)[0]
        good = [a for a in starts if a + LS <= len(rows) and (rows[a:a + LS, 0] == np.arange(LS)).all()]
        lines = [rows[a:a + LS, 1] for a in good]
        # optional columns 3, 4: feed-forward (pal, ntsc) on the x = 1279 row
        ffl = [(int(rows[a + LS - 1, 2]), int(rows[a + LS - 1, 3])) for a in good] if rows.shape[1] >= 4 else None
        lg = []
        res = chroma_decode(lines, is_pal="pal" in sys.argv[4:], comb="notch" not in sys.argv[4:], log=lg,
                            legacy_lock="legacy" in sys.argv[4:], ff=ffl)
        logp = next((a.split("=", 1)[1] for a in sys.argv[4:] if a.startswith("--log=")), None)
        if logp:
            with open(logp, "w") as f:
                f.write("".join(f"{a} {b} {c} {d}\n" for a, b, c, d in lg))
        with open(sys.argv[3], "w") as f:
            for Y, U, V in res:
                for x in range(LS):
                    f.write(f"{x} {Y[x]} {U[x]} {V[x]}\n")
        print(f"decoded {len(res)} lines")
