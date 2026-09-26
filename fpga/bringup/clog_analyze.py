#!/usr/bin/env python3
"""Decode colour-lock recordings saved by `link_sniff.py --clog=PREFIX` (rtl/dsp/chroma_log.v).

  python3 bringup/clog_analyze.py REC.hex [...] [-v]

Each recording is 256 consecutive line records of chroma_dec's burst loop: burst U / V (>> 8),
the NCO correction applied at the line end, the H sync edge error, and the flags {flip, V switch,
colour killer, field start}. Prints per recording: burst magnitude, lines held (no burst),
flips and runs of consecutive flips (the old lock's false state: bands of hue-inverted lines),
lines whose burst sits in the wrong half plane (reference ~180 degrees off), and the sync edge
error. -v lists every line.
"""
import math
import sys


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def records(path):
    w = [int(l, 16) for l in open(path) if l.strip()]
    out = []
    for n in range(len(w) // 4):
        bv, bu, lo, corr = s16(w[4 * n]), s16(w[4 * n + 1]), w[4 * n + 2], w[4 * n + 3]
        perr = lo >> 4
        perr = (perr - 4096 if perr & 0x800 else perr) / 16.0
        out.append(dict(bu=bu, bv=bv, corr=s16(corr), perr=perr, flip=lo >> 3 & 1, sw=lo >> 2 & 1,
                        killed=lo >> 1 & 1, fs=lo & 1))
    return out


verbose = "-v" in sys.argv
for path in [a for a in sys.argv[1:] if not a.startswith("-")]:
    r = records(path)
    mags = sorted(math.hypot(x["bu"], x["bv"]) for x in r)
    med = mags[len(mags) // 2]
    flips = [i for i, x in enumerate(r) if x["flip"]]
    runs, cur = [], 0
    for x in r:
        if x["flip"]: cur += 1
        elif cur: runs.append(cur); cur = 0
    if cur: runs.append(cur)
    wrong = [i for i, x in enumerate(r) if math.hypot(x["bu"], x["bv"]) > 0.3 * med and x["bu"] > 0]
    held = sum(1 for x in r if x["corr"] == 0)
    pe = [abs(x["perr"]) for x in r if x["perr"] != 0]
    print(f"{path}: {len(r)} lines, burst magnitude median {med:.0f}, held {held}, flips {len(flips)} "
          f"(runs {sorted(runs, reverse=True)[:8]}), burst in the wrong half plane {len(wrong)}, "
          f"killed {sum(x['killed'] for x in r)}, field starts {sum(x['fs'] for x in r)}, "
          f"|sync edge error| median {sorted(pe)[len(pe) // 2] if pe else 0:.2f} max {max(pe) if pe else 0:.2f} samples")
    if verbose:
        for i, x in enumerate(r):
            a = math.degrees(math.atan2(x["bv"], x["bu"]))
            print(f"  {i:3d} bu {x['bu']:6d} bv {x['bv']:6d} angle {a:+7.1f} corr {x['corr'] * 360 / 65536:+7.1f} deg "
                  f"perr {x['perr']:+6.2f} {'FLIP' if x['flip'] else '    '} {'sw' if x['sw'] else '  '} "
                  f"{'KILL' if x['killed'] else ''} {'FIELD' if x['fs'] else ''}")
