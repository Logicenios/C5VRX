#!/usr/bin/env python3
"""Integer reference of the FPGA decode pipeline (bit-exact where the RTL must be).

Stages mirror fpga/rtl/dsp (see fpga/README.md "Pipeline"):
  fm_frontend: phase LUT -> adjacent discriminator (k=1 @ 40 MS/s, THEORY §5.1)
               -> click repair (THEORY §10) -> halfband 2:1 -> de-emphasis (THEORY §6.3)
Units: phase 1/65536 turn; frequency word 1 LSB = 40e6/65536 = 610.35 Hz.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

HZ_PER_LSB = 40e6 / 65536

# ---- click repair thresholds (THEORY §10) ----
CLICK_ABS = 22937        # |f| > 14 MHz cannot be video (THEORY §2.3 peak deviation)
CLICK_R2_LOW = 10        # I/Q radius^2 (in half-LSB^2 units) below ~1.6 nibble LSB: phase unreliable
CLICK_JUMP = 8192        # 5 MHz jump in one 25 ns step while the vector is near the origin

# ---- halfband 40 -> 20 MS/s: [-1 0 9 16 9 0 -1] / 32 ----
HB = [-1, 0, 9, 16, 9, 0, -1]

# ---- de-emphasis (THEORY §6.3) at 20 MS/s, Q14, bilinear transform ----
FS2 = 20e6
TAU_P = 0.8162e-6
TAU_Z = TAU_P / 10 ** (13.4 / 20)


# Runtime de-emphasis modes (menu "De-emphasis", fm_frontend deemph input): roof in dB, same
# tau_p. The Tank II transmits with little or no pre-emphasis (MEASUREMENTS M76): the 13.4 dB
# NTSC roof then cuts chroma by ~13 dB and smears edges; None = off (exact pass-through).
DEEMPH_ROOF = {0: 13.4, 1: 8.0, 2: 4.0, 3: None}

# Video low-pass after the de-emphasis (menu "Noise filter"): 25-tap linear-phase FIR at 20 MS/s,
# scipy.signal.remez(25, [0, 5.3e6, 7.0e6, 10e6], [1, 0], weight=[1, 3], fs=20e6) in Q12 with
# the centre tap adjusted for exact unity DC gain. Flat to 5.3 MHz (0.3 dB ripple, 4.43 MHz
# -0.28 dB), -33 dB from 7 MHz: removes ~7 dB of the f^2 discriminator noise above the video
# band without the one-sided smear of a shelf (MEASUREMENTS M77). Delay 12 samples.
LPF_Q = 12
LPF_HALF = [-4, 47, 15, -68, 40, 86, -143, -25, 278, -212, -396, 1219, 2422]
LPF_C = LPF_HALF + LPF_HALF[-2::-1]
assert sum(LPF_C) == 1 << LPF_Q


def deemph_coeffs(q: int = 14, roof_db: float | None = 13.4):
    s = 1 << q
    if roof_db is None:
        return s, 0, 0
    tau_z = TAU_P / 10 ** (roof_db / 20)
    k = 2 * FS2
    a0 = 1 + k * TAU_P
    b0 = (1 + k * tau_z) / a0
    b1 = (1 - k * tau_z) / a0
    a1 = (1 - k * TAU_P) / a0          # y = b0 x + b1 x1 - a1 y1
    B0, B1, A1N = round(b0 * s), round(b1 * s), round(-a1 * s)
    # force exact unity DC gain: B0 + B1 == s - A1N
    B1 = (s - A1N) - B0
    return B0, B1, A1N


def phase_lut():
    ph = np.zeros(256, dtype=np.int64)
    r2 = np.zeros(256, dtype=np.int64)
    for b in range(256):
        si = (b >> 4) - 16 if (b >> 4) & 8 else (b >> 4)
        sq = (b & 15) - 16 if (b & 15) & 8 else (b & 15)
        ang = math.atan2(64 * sq + 31.5, 64 * si + 31.5) / (2 * math.pi)
        ph[b] = int(math.floor(ang * 65536 + 0.5)) & 0xFFFF
        r2[b] = (2 * si + 1) ** 2 + (2 * sq + 1) ** 2
    return ph, r2


def s16(x: int) -> int:
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def fm_frontend(raw: np.ndarray, deemph: int = 0, lpf: bool = False):
    """Returns (d40, y40, e20): discriminator, click-repaired, de-emphasised 20 MS/s."""
    ph, r2 = phase_lut()
    n = len(raw)
    d = np.zeros(n, dtype=np.int64)
    click = np.zeros(n, dtype=bool)
    for i in range(1, n):
        d[i] = s16(int(ph[raw[i]]) - int(ph[raw[i - 1]]))
    y = np.zeros(n, dtype=np.int64)
    for i in range(1, n - 1):
        r2min = min(r2[raw[i]], r2[raw[i - 1]])
        c = abs(d[i]) > CLICK_ABS or (r2min < CLICK_R2_LOW and abs(d[i] - y[i - 1]) > CLICK_JUMP)
        click[i] = c
        y[i] = (y[i - 1] + d[i + 1]) >> 1 if c else d[i]
    # halfband, output at every even index k>=6
    z = []
    for k in range(6, n - 1, 2):
        acc = sum(HB[t] * int(y[k - t]) for t in range(7))
        z.append(acc >> 5)
    z = np.array(z, dtype=np.int64)
    B0, B1, A1N = deemph_coeffs(roof_db=DEEMPH_ROOF[deemph])
    e = np.zeros(len(z), dtype=np.int64)
    x1 = 0
    yf1 = 0                                  # output with 4 fractional bits
    for m, x in enumerate(z):
        acc = B0 * x * 16 + B1 * x1 * 16 + A1N * yf1
        yf = acc >> 14
        e[m] = yf >> 4
        x1, yf1 = int(x), yf
    if lpf:                                  # FIR over e with zero history, round half up
        ep = np.concatenate([np.zeros(len(LPF_C) - 1, dtype=np.int64), e])
        e = np.array([(sum(LPF_C[k] * int(ep[m + len(LPF_C) - 1 - k]) for k in range(len(LPF_C)))
                       + (1 << (LPF_Q - 1))) >> LPF_Q for m in range(len(e))], dtype=np.int64)
    return d, y, e, click


def write_luts(outdir: Path) -> None:
    ph, r2 = phase_lut()
    with open(outdir / "phase_lut.hex", "w") as f:
        for b in range(256):
            f.write(f"{(int(r2[b]) << 16) | int(ph[b]):07x}\n")    # {r2[8:0], phase[15:0]}
    for m, roof in DEEMPH_ROOF.items():
        B0, B1, A1N = deemph_coeffs(roof_db=roof)
        print(f"de-emphasis mode {m} (roof {roof} dB) Q14: B0={B0} B1={B1} A1N={A1N}")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "luts":
        write_luts(Path(sys.argv[2]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "frontend":
        raw = np.array([int(l, 16) for l in open(sys.argv[2]) if l.strip()], dtype=np.int64)
        d, y, e, click = fm_frontend(raw, deemph=int(sys.argv[4]) if len(sys.argv) >= 5 else 0,
                                     lpf=len(sys.argv) >= 6 and sys.argv[5] == "1")
        with open(sys.argv[3], "w") as f:
            f.write("\n".join(str(int(v)) for v in e) + "\n")
        print(f"frontend: {len(raw)} in, {len(e)} out, clicks={int(click.sum())}, "
              f"mean f = {e[len(e)//2:].mean() * HZ_PER_LSB / 1e3:.1f} kHz")
