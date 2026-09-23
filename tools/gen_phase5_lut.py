#!/usr/bin/env python3
"""Generate the GOLDEN Phase5 BitScrambler LUT from docs/THEORY.md constants.

The 1024x16 LUT is dual-purpose (THEORY §5.5):
  LUT[byte][12:8]           = phase5 state of a raw Q4/I4 byte  (THEORY §4.1, §5.3)
  LUT[(prev<<5)|cur][5:0]   = 6-bit DAC code for the 50 ns phase step (THEORY §5.5)

Usage:
  gen_phase5_lut.py --check          verify src/fm.bsasm and src/fm4.bsasm
  gen_phase5_lut.py --write          rewrite the embedded LUT lines
  gen_phase5_lut.py --variant foldback --print   reproduce upstream e7f38f2 (rejected)
"""

from __future__ import annotations

import argparse
import functools
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGETS = [ROOT / "src" / "fm.bsasm", ROOT / "src" / "fm4.bsasm"]
TAU = 2.0 * math.pi

# THEORY §5.5 / MEASUREMENTS M29: pedestal and "gain 2" (= 3/4 of a phase8 step)
# were chosen on hardware for one VTX. Not level-normalised (THEORY §9).
PEDESTAL = 20
GAIN_NUM, GAIN_DEN = 3, 4
CODE_MAX = 63


def bucket_center(nibble: int) -> float:
    """THEORY §4.1: signed nibble -8..+7 -> centre of its 10-bit bucket, 64*s + 31.5.

    Kept in 10-bit units (not s + 0.5) so floating-point ties at exact bin
    boundaries resolve exactly like the hardware-proven upstream table.
    """
    s = nibble - 16 if nibble & 8 else nibble
    return 64.0 * s + 31.5


def byte_phase(byte: int) -> float:
    """Exact phase of a PARLIO byte: I in bits 7..4, Q in bits 3..0 (THEORY §4.1)."""
    return math.atan2(bucket_center(byte & 0x0F), bucket_center(byte >> 4))


def phase5(byte: int) -> int:
    # Python round() (half-to-even) matches the upstream hardware-proven table.
    return round(byte_phase(byte) * 32.0 / TAU) & 31


@functools.lru_cache(maxsize=None)
def centroid_phase8() -> tuple[int, ...]:
    """Circular mean phase of every phase5 bin, in 1/256 turn (THEORY §5.5)."""
    out = []
    for state in range(32):
        members = [byte_phase(b) for b in range(256) if phase5(b) == state]
        mean = math.atan2(sum(map(math.sin, members)), sum(map(math.cos, members)))
        out.append(round(mean * 256.0 / TAU))
    return tuple(out)


def scale(delta8: int) -> int:
    """Round-half-away of GAIN_NUM/GAIN_DEN * delta8 (upstream integer form)."""
    n = delta8 * GAIN_NUM
    half = GAIN_DEN // 2
    return -((-n + half) // GAIN_DEN) if n < 0 else (n + half) // GAIN_DEN


def dac_code(prev: int, cur: int, variant: str) -> int:
    c = centroid_phase8()
    delta8 = (c[cur] - c[prev] + 128) % 256 - 128
    code = max(0, min(CODE_MAX, PEDESTAL + scale(delta8)))
    if variant == "foldback":
        # Upstream e7f38f2 "soft-noise squelch": non-monotone, rejected by THEORY §5.5/§10.
        d = (cur - prev + 16) % 32 - 16
        fold = {9: 60, 10: 48, 11: 36, -9: 8, -10: 14, -11: 18}
        if abs(d) >= 12:
            code = PEDESTAL
        elif d in fold:
            code = fold[d]
    return code


def build_lut(variant: str = "golden") -> list[int]:
    lut = [dac_code(p, c, variant) for p in range(32) for c in range(32)]
    for byte in range(256):
        lut[byte] |= phase5(byte) << 8
    return lut


LUT_RE = re.compile(r"^lut [0-9 ]+$", re.M)


def lut_line(lut: list[int]) -> str:
    return "lut " + " ".join(map(str, lut))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--variant", choices=["golden", "foldback"], default="golden")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--print", action="store_true")
    args = ap.parse_args(argv)

    lut = build_lut(args.variant)
    if args.print:
        print(lut_line(lut))
        return 0
    ok = True
    for path in TARGETS:
        text = path.read_text()
        if len(LUT_RE.findall(text)) != 1:
            print(f"{path.name}: expected exactly one 'lut' line", file=sys.stderr)
            return 1
        if args.write:
            path.write_text(LUT_RE.sub(lut_line(lut), text))
            print(f"{path.name}: wrote {args.variant} LUT")
        elif lut_line(lut) not in text:
            print(f"{path.name}: embedded LUT differs from {args.variant} generator", file=sys.stderr)
            ok = False
        else:
            print(f"{path.name}: {args.variant} LUT OK")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
