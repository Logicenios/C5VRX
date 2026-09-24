#!/usr/bin/env python3
"""Analyse a raw link capture saved by `link_sniff.py --capture=PREFIX` (2048 words,
word = {falling-edge byte (earlier), rising-edge byte (later)}, 25 ns per word).

  python3 bringup/cap_analyze.py CAPTURE.hex [PNG]

Reports amplitude, phase-step and click statistics for the rising-edge stream (what the FPGA
demodulates), the falling-edge stream and the interleaved ~80 MS/s stream, for the documented
byte layout and for alternative bit layouts, and the demodulated frequency track through the
bit-exact front-end model (model/ref.py). A clean FM capture has small phase steps, few clicks,
and a frequency track with a ~4.7 us sync dip per 64 us line.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
from ref import HZ_PER_LSB, fm_frontend, phase_lut  # noqa: E402

PH, R2 = phase_lut()


def rev4(n: int) -> int:
    return int(f"{n:04b}"[::-1], 2)


LAYOUTS = {
    "documented {I,Q}": lambda b: b,
    "I/Q swapped": lambda b: ((b & 15) << 4) | (b >> 4),
    "nibble bits reversed": lambda b: (rev4(b >> 4) << 4) | rev4(b & 15),
}


def stats(stream: np.ndarray, label: str) -> None:
    ph = PH[stream].astype(np.int64)
    d = (np.diff(ph) + 32768) % 65536 - 32768                  # phase step, 1/65536 turn
    big = np.mean(np.abs(d) > 16384)                           # > 90 deg per step
    r = np.sqrt(R2[stream] / 4.0)                              # radius in nibble LSB
    print(f"  {label:34s} radius mean {r.mean():4.1f} LSB (min-state share {np.mean(R2[stream] <= 2):4.0%}), "
          f"|step| median {np.median(np.abs(d)) * 360 / 65536:5.1f} deg, >90 deg {big:5.1%}")


def main() -> None:
    words = np.array([int(l, 16) for l in open(sys.argv[1]) if l.strip()], dtype=np.int64)
    dp, dn = words & 0xFF, words >> 8
    inter = np.empty(2 * len(words), dtype=np.int64)
    inter[0::2], inter[1::2] = dn, dp                         # time order: falling, then rising
    print(f"{sys.argv[1]}: {len(words)} STROBE cycles ({len(words) * 25e-3:.1f} us)")
    for name, f in LAYOUTS.items():
        m = np.vectorize(f)
        print(f" layout: {name}")
        stats(m(dp), "rising edge, 40 MS/s (FPGA input)")
        stats(m(dn), "falling edge, 40 MS/s")
        stats(m(inter), "interleaved, 80 MS/s")
    # demodulated frequency, documented layout, rising-edge stream (= the FPGA's front end)
    d40, y40, e20, click = fm_frontend(dp)
    f = e20 * HZ_PER_LSB / 1e6
    print(f" front end (documented layout, rising edge): clicks {click.mean():.1%}, "
          f"frequency mean {f.mean():+.2f} MHz, p5 {np.percentile(f, 5):+.2f} p50 {np.median(f):+.2f} "
          f"p95 {np.percentile(f, 95):+.2f} MHz")
    k = 10                                                     # 0.5 us boxcar at 20 MS/s
    fs = np.convolve(f, np.ones(k) / k, mode="valid")
    lo = fs < (np.percentile(fs, 5) + 0.25 * (np.median(fs) - np.percentile(fs, 5)))
    runs, cur = [], 0
    for v in lo:
        if v: cur += 1
        elif cur: runs.append(cur); cur = 0
    if cur: runs.append(cur)
    long_runs = [r / 20 for r in runs if r >= 40]              # >= 2 us below the low threshold
    print(f" low-frequency runs >= 2 us (sync candidates): {['%.1f us' % r for r in long_runs] or 'none'}")
    if len(sys.argv) > 2:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            fig, ax = plt.subplots(3, 1, figsize=(11, 8))
            ax[0].plot(np.arange(len(f)) / 20, f, lw=0.6); ax[0].set_ylabel("MHz"); ax[0].set_xlabel("us")
            ax[0].set_title("demodulated frequency (rising edge, bit-exact front end)")
            ii = ((dp >> 4) ^ 8) - 8; qq = ((dp & 15) ^ 8) - 8
            ax[1].hist2d(ii + 0.5, qq + 0.5, bins=16, range=[[-8, 8], [-8, 8]]); ax[1].set_aspect("equal")
            ax[1].set_title("constellation (rising edge)")
            ph = PH[dp].astype(np.int64); d = (np.diff(ph) + 32768) % 65536 - 32768
            ax[2].hist(d * 360 / 65536, bins=90); ax[2].set_title("phase step per 25 ns (deg)")
            fig.tight_layout(); fig.savefig(sys.argv[2], dpi=90)
            print(f" plot -> {sys.argv[2]}")
        except ImportError:
            print(" (matplotlib not installed: no plot)")


if __name__ == "__main__":
    main()
