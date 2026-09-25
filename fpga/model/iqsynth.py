#!/usr/bin/env python3
"""Synthesize the C5 MODEM_DIAG byte stream for a colour-bar test signal.

composite video (SMPTE 75 % bars for NTSC, EBU 75 % bars for PAL, with sync,
burst and blanking)  ->  VTX pre-emphasis (THEORY §6.2, inverse of the roofed
shelf)  ->  FM with deviation K Hz/V and a carrier offset  ->  complex baseband
at 40 MS/s  ->  AWGN  ->  4-bit I/Q nibbles (signed, top 4 of 10 bits;
THEORY §4.1) packed as byte = I<<4 | Q (MEASUREMENTS M12).

Output: one hex byte per line (for $readmemh) and a .npy of the composite (V).
"""
from __future__ import annotations

import argparse
import math
import numpy as np

FS = 40e6

STD = {
    # line period, lines/frame, fsc, burst start after sync leading edge, cycles
    "ntsc": dict(line=63.5555555e-6, lines=525, fsc=3579545.4545, burst_t=5.3e-6, burst_cyc=9,
                 active_t=9.4e-6, active_len=52.66e-6, sync=-0.2857, white=0.7143, setup=0.0536,
                 burst_amp=0.1429),
    "pal":  dict(line=64e-6, lines=625, fsc=4433618.75, burst_t=5.6e-6, burst_cyc=10,
                 active_t=10.5e-6, active_len=52.0e-6, sync=-0.3, white=0.7, setup=0.0,
                 burst_amp=0.15),
}

# 75 % bars as (R', G', B') gamma-corrected
BARS = [(0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
        (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75), (0, 0, 0)]


def composite(std: str, seconds: float, fs: float = FS, ppm: float = 0.0, chroma_gain: float = 1.0) -> np.ndarray:
    """ppm: VTX clock error (line and subcarrier both scale; a real VTX crystal is never exactly
    on our 40 MHz, so its sync edges drift across the sample grid). chroma_gain scales the
    chroma and the burst (the Tank II burst arrives at ~0.38 of nominal, MEASUREMENTS M76)."""
    p = STD[std]
    n = int(seconds * fs)
    t = np.arange(n) / fs * (1.0 + ppm * 1e-6)
    line = p["line"]
    lines = p["lines"]
    frame = line * lines / 2.0          # field period (interlace ignored for bars: every line active)
    tl = np.mod(t, line)                # time within line
    ln = np.floor(t / line).astype(np.int64)
    field_line = np.mod(ln, lines // 2)
    v = np.zeros(n)

    # vertical: first 9 lines of each field are broad/equalising sync (simplified: broad pulses)
    vblank = field_line < 20
    vsync = field_line < 3
    hsync = tl < 4.7e-6

    wsc = 2 * math.pi * p["fsc"]
    act = (tl >= p["active_t"]) & (tl < p["active_t"] + p["active_len"])
    bar = np.clip(((tl - p["active_t"]) / p["active_len"] * 8).astype(int), 0, 7)
    rgb = np.array(BARS)[bar]
    y = 0.299 * rgb[:, 0] + 0.587 * rgb[:, 1] + 0.114 * rgb[:, 2]
    u = 0.492 * (rgb[:, 2] - y)
    vv = 0.877 * (rgb[:, 0] - y)
    pal_sw = np.where((ln % 2) == 1, -1.0, 1.0) if std == "pal" else 1.0
    chroma = chroma_gain * (u * np.sin(wsc * t) + vv * pal_sw * np.cos(wsc * t))
    video = p["setup"] + y * (p["white"] - p["setup"]) + chroma * p["white"]
    v = np.where(act & ~vblank, video, 0.0)

    burst = (tl >= p["burst_t"]) & (tl < p["burst_t"] + p["burst_cyc"] / p["fsc"]) & ~vblank
    if std == "ntsc":
        bsig = -chroma_gain * p["burst_amp"] * np.sin(wsc * t)                          # 180 deg on -U
    else:
        bsig = chroma_gain * p["burst_amp"] * (-np.sin(wsc * t) + pal_sw * np.cos(wsc * t)) / math.sqrt(2)
    v = np.where(burst, bsig, v)
    v = np.where(hsync & ~vsync, p["sync"], v)
    v = np.where(vsync & (tl < line - 4.7e-6), p["sync"], v)  # broad pulses
    return v


def preemphasis(v: np.ndarray, fs: float = FS, tau_p=0.8162e-6, roof_db=13.4) -> np.ndarray:
    """Inverse of THEORY §6.2 de-emphasis: H_pre = (1 + s tau_p)/(1 + s tau_z), bilinear."""
    tau_z = tau_p / 10 ** (roof_db / 20)
    k = 2 * fs
    b0, b1 = (1 + k * tau_p), (1 - k * tau_p)
    a0, a1 = (1 + k * tau_z), (1 - k * tau_z)
    out = np.zeros_like(v)
    x1 = y1 = 0.0
    for i, x in enumerate(v):
        y = (b0 * x + b1 * x1 - a1 * y1) / a0
        out[i] = y
        x1, y1 = x, y
    return out


def fm_iq(v: np.ndarray, dev_hz_per_v: float, offset_hz: float, radius: float,
          noise: float, seed: int, fs: float = FS) -> np.ndarray:
    f = offset_hz + dev_hz_per_v * v
    phase = 2 * math.pi * np.cumsum(f) / fs
    rng = np.random.default_rng(seed)
    iq = radius * np.exp(1j * phase) + noise * (rng.standard_normal(len(v)) + 1j * rng.standard_normal(len(v)))
    return iq


def quantize(iq: np.ndarray) -> np.ndarray:
    """10-bit signed ADC (+-512) -> top nibble. radius is in 10-bit LSB."""
    i10 = np.clip(np.floor(iq.real), -512, 511).astype(int)
    q10 = np.clip(np.floor(iq.imag), -512, 511).astype(int)
    i4 = (i10 >> 6) & 0xF
    q4 = (q10 >> 6) & 0xF
    return ((i4 << 4) | q4).astype(np.uint8)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--std", choices=["ntsc", "pal"], default="ntsc")
    ap.add_argument("--seconds", type=float, default=0.04)
    ap.add_argument("--dev", type=float, default=3.4e6, help="deviation Hz per volt (Tank II ~ A/0.3V, M56)")
    ap.add_argument("--offset", type=float, default=-150e3, help="carrier offset Hz (M54/M56)")
    ap.add_argument("--radius", type=float, default=320.0, help="ADC radius in 10-bit LSB (~5 nibble LSB)")
    ap.add_argument("--noise", type=float, default=15.0, help="noise sigma per axis, 10-bit LSB")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--ppm", type=float, default=0.0, help="VTX clock error in ppm (sync edges drift)")
    ap.add_argument("--chroma", type=float, default=1.0, help="chroma and burst level (1 = nominal)")
    ap.add_argument("--no-preemphasis", action="store_true")
    ap.add_argument("--out", required=True, help="output prefix")
    a = ap.parse_args()
    v = composite(a.std, a.seconds, ppm=a.ppm, chroma_gain=a.chroma)
    vp = v if a.no_preemphasis else preemphasis(v)
    b = quantize(fm_iq(vp, a.dev, a.offset, a.radius, a.noise, a.seed))
    with open(a.out + ".hex", "w") as f:
        f.write("\n".join(f"{x:02x}" for x in b) + "\n")
    np.save(a.out + "_composite.npy", v)
    print(f"{a.std}: {len(b)} samples -> {a.out}.hex")


if __name__ == "__main__":
    main()
