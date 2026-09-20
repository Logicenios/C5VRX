#!/usr/bin/env python3
"""C5VRX weak-signal demod/range benchmark.

Consumes raw packed Q4/I4 bytes from MODEM_DIAG captures and compares:
  * current 50 ns Phase5 endpoint discriminator;
  * exact adjacent 25 ns + 25 ns pair-sum;
  * confidence-aware adjacent repair (offline experiment);
  * a second-order PLL tracker (offline threshold-extension experiment).

This tool is deliberately offline. It is used to prove an algorithm on the
same capture before any realtime BitScrambler/M2M path is promoted.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

TAU = 2.0 * math.pi

# Exact Phase5 mapping mirrored from main/video.c / fm.bsasm.
PHASE5 = [
     4,  6,  7,  7,  7,  8,  8,  8, 24, 24, 24, 25, 25, 25, 26, 28,
     2,  4,  5,  6,  6,  7,  7,  7, 25, 25, 25, 26, 26, 27, 28, 30,
     1,  3,  4,  5,  5,  6,  6,  6, 26, 26, 26, 27, 27, 28, 29, 31,
     1,  2,  3,  4,  5,  5,  5,  6, 26, 27, 27, 27, 28, 29, 30, 31,
     1,  2,  3,  3,  4,  5,  5,  5, 27, 27, 27, 28, 29, 29, 30, 31,
     0,  1,  2,  3,  3,  4,  4,  5, 27, 28, 28, 28, 29, 30, 31,  0,
     0,  1,  2,  3,  3,  4,  4,  4, 28, 28, 28, 29, 29, 30, 31,  0,
     0,  1,  2,  2,  3,  3,  4,  4, 28, 28, 29, 29, 30, 30, 31,  0,
    16, 15, 14, 14, 13, 13, 12, 12, 20, 20, 19, 19, 18, 18, 17, 16,
    16, 15, 14, 13, 13, 12, 12, 12, 20, 20, 20, 19, 19, 18, 17, 16,
    16, 15, 14, 13, 13, 12, 12, 11, 21, 20, 20, 19, 19, 18, 17, 16,
    15, 14, 13, 13, 12, 12, 11, 11, 21, 21, 21, 20, 19, 19, 18, 17,
    15, 14, 13, 12, 11, 11, 11, 10, 22, 21, 21, 21, 20, 19, 18, 17,
    15, 13, 12, 11, 11, 10, 10, 10, 22, 22, 22, 21, 21, 20, 19, 17,
    14, 12, 11, 10, 10,  9,  9,  9, 23, 23, 23, 22, 22, 21, 20, 18,
    12, 10,  9,  9,  9,  8,  8,  8, 24, 24, 24, 23, 23, 23, 22, 20,
]


def s4(v: int) -> int:
    return v - 16 if v & 8 else v


def unpack(byte: int) -> Tuple[int, int]:
    q = s4(byte & 0xF)
    i = s4((byte >> 4) & 0xF)
    return i, q


def power(byte: int) -> int:
    i, q = unpack(byte)
    return i * i + q * q


def phase_rad(byte: int) -> float:
    i, q = unpack(byte)
    return math.atan2(q, i)


def wrap(x: float) -> float:
    while x > math.pi:
        x -= TAU
    while x <= -math.pi:
        x += TAU
    return x


def d5(a: int, b: int) -> int:
    d = (b & 31) - (a & 31)
    if d > 15:
        d -= 32
    elif d < -16:
        d += 32
    return d


def median3(a: float, b: float, c: float) -> float:
    return sorted((a, b, c))[1]


@dataclass
class PairMetrics:
    pairs: int = 0
    winding_disagree: int = 0
    strong_pairs: int = 0
    strong_winding: int = 0
    low_conf_pairs: int = 0
    endpoint_impulses: int = 0
    adjacent_impulses: int = 0
    repaired_impulses: int = 0


def phase5_pair_metrics(data: bytes, parity: int, low_power: int) -> PairMetrics:
    m = PairMetrics()
    phases = [PHASE5[b] for b in data]
    powers = [power(b) for b in data]

    # Endpoint path uses selected samples parity, parity+2, ... and therefore
    # discards the middle 40 MS/s sample before the branch decision.
    for end in range(parity + 2, len(data), 2):
        a, mid, c = end - 2, end - 1, end
        d0 = d5(phases[a], phases[mid])
        d1 = d5(phases[mid], phases[c])
        adjacent = d0 + d1
        endpoint = d5(phases[a], phases[c])
        m.pairs += 1
        if adjacent != endpoint:
            m.winding_disagree += 1
        strong = min(powers[a], powers[mid], powers[c]) >= 64
        if strong:
            m.strong_pairs += 1
            if adjacent != endpoint:
                m.strong_winding += 1
        low = min(powers[a], powers[mid], powers[c]) < low_power
        if low:
            m.low_conf_pairs += 1

        # "Impulse" is deliberately only a comparative tail metric here, not
        # a video-validity decision.
        if abs(endpoint) >= 12:
            m.endpoint_impulses += 1
        if abs(adjacent) >= 20:
            m.adjacent_impulses += 1

        # Offline confidence repair: only alter a delta when the involved IQ
        # is weak AND it is a strong local outlier. This is intentionally
        # conservative and exists to measure potential, not to claim live use.
        repaired0, repaired1 = float(d0), float(d1)
        if end >= parity + 4:
            pm2 = d5(phases[end - 4], phases[end - 3])
            pm1 = d5(phases[end - 3], phases[end - 2])
            local = median3(float(pm2), float(pm1), float(d0))
            if min(powers[a], powers[mid]) < low_power and abs(d0 - local) >= 8:
                repaired0 = local
        if end + 1 < len(data):
            nxt = d5(phases[c], phases[end + 1])
            local = median3(float(d0), float(d1), float(nxt))
            if min(powers[mid], powers[c]) < low_power and abs(d1 - local) >= 8:
                repaired1 = local
        if abs(repaired0 + repaired1) >= 20:
            m.repaired_impulses += 1
    return m


@dataclass
class PllResult:
    phase_error_rms: float
    impulse_permille: float
    output: List[float]


def pll_demod(
    data: Sequence[int],
    sample_rate: float,
    loop_bw: float,
    max_dev: float,
) -> PllResult:
    wn = min(TAU * loop_bw / sample_rate, 0.5)
    zeta = 1.0 / math.sqrt(2.0)
    kp = 2.0 * zeta * wn
    ki = wn * wn
    freq_max = TAU * max_dev / sample_rate * 1.25

    nco_phase = 0.0
    freq = 0.0
    err_sq = 0.0
    out: List[float] = []
    impulses = 0

    for idx, b in enumerate(data):
        ph = phase_rad(b)
        e = wrap(ph - nco_phase)
        freq = max(-freq_max, min(freq_max, freq + ki * e))
        inst = freq + kp * e
        out.append(inst)
        nco_phase = wrap(nco_phase + inst)
        err_sq += (e * e - err_sq) / 256.0
        if idx > 0 and abs(inst) >= math.pi * 0.75:
            impulses += 1

    return PllResult(
        phase_error_rms=math.sqrt(max(0.0, err_sq)),
        impulse_permille=1000.0 * impulses / max(1, len(data) - 1),
        output=out,
    )


def discriminator(data: Sequence[int]) -> List[float]:
    if len(data) < 2:
        return []
    phases = [phase_rad(b) for b in data]
    return [wrap(phases[i] - phases[i - 1]) for i in range(1, len(phases))]


def percentile_abs(values: Sequence[float], p: float) -> float:
    if not values:
        return 0.0
    xs = sorted(abs(x) for x in values)
    pos = min(len(xs) - 1, max(0, int(round((len(xs) - 1) * p))))
    return xs[pos]


def analyze(data: bytes, args: argparse.Namespace) -> dict:
    parity = 1 if args.parity == "odd" else 0
    m = phase5_pair_metrics(data, parity, args.low_power)
    disc = discriminator(data)
    pll = pll_demod(data, args.sample_rate, args.loop_bw, args.max_deviation)

    origin = sum(power(b) <= 4 for b in data)
    clipped = sum(
        (lambda iq: iq[0] in (-8, 7) or iq[1] in (-8, 7))(unpack(b))
        for b in data
    )

    def pm(num: int, den: int) -> float:
        return 1000.0 * num / max(1, den)

    return {
        "samples": len(data),
        "q4_origin_permille": pm(origin, len(data)),
        "q4_clip_permille": pm(clipped, len(data)),
        "phase5_endpoint_pairs": m.pairs,
        "phase5_endpoint_winding_disagree_permille": pm(m.winding_disagree, m.pairs),
        "phase5_strong_winding_disagree_permille": pm(m.strong_winding, m.strong_pairs),
        "phase5_low_conf_pair_permille": pm(m.low_conf_pairs, m.pairs),
        "endpoint_impulse_permille": pm(m.endpoint_impulses, m.pairs),
        "adjacent_pairsum_impulse_permille": pm(m.adjacent_impulses, m.pairs),
        "confidence_repair_impulse_permille": pm(m.repaired_impulses, m.pairs),
        "full_q4_discriminator_abs_p95_rad": percentile_abs(disc, 0.95),
        "full_q4_discriminator_abs_p99_rad": percentile_abs(disc, 0.99),
        "pll_loop_bw_hz": args.loop_bw,
        "pll_phase_error_rms_rad": pll.phase_error_rms,
        "pll_impulse_permille": pll.impulse_permille,
    }


def synthetic_self_test() -> None:
    rng = random.Random(0xC5)
    fs = 40_000_000.0
    n = 20_000
    phase = 0.0
    raw = bytearray()
    truth: List[float] = []

    for k in range(n):
        # Wide-FM-ish deterministic modulation, safely below Nyquist.
        inst = 0.42 * math.sin(TAU * k / 173.0) + 0.08 * math.sin(TAU * k / 41.0)
        phase = wrap(phase + inst)
        truth.append(inst)
        amp = 6.0
        i = amp * math.cos(phase) + rng.gauss(0.0, 0.35)
        q = amp * math.sin(phase) + rng.gauss(0.0, 0.35)
        qi = max(-8, min(7, int(round(q)))) & 0xF
        ii = max(-8, min(7, int(round(i)))) & 0xF
        raw.append((ii << 4) | qi)

    disc = discriminator(raw)
    assert len(disc) == n - 1
    # On clean-ish synthetic data the adjacent full-Q4 discriminator should
    # track the known instantaneous frequency with bounded quantization error.
    mse = sum((disc[k - 1] - truth[k]) ** 2 for k in range(1, n)) / (n - 1)
    assert mse < 0.08, mse

    pll = pll_demod(raw, fs, 2_500_000.0, 6_000_000.0)
    assert math.isfinite(pll.phase_error_rms)
    assert len(pll.output) == n

    m = phase5_pair_metrics(raw, 1, 8)
    assert m.pairs > 1000
    print(
        "range_demod_bench self-test passed: "
        f"disc_mse={mse:.5f} pairs={m.pairs} winding_pm="
        f"{1000.0*m.winding_disagree/max(1,m.pairs):.2f}"
    )


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("capture", nargs="?", type=Path, help="raw packed Q4/I4 capture")
    p.add_argument("--parity", choices=("odd", "even"), default="odd")
    p.add_argument("--low-power", type=int, default=8)
    p.add_argument("--sample-rate", type=float, default=40_000_000.0)
    p.add_argument("--loop-bw", type=float, default=2_500_000.0)
    p.add_argument("--max-deviation", type=float, default=6_000_000.0)
    p.add_argument("--json", action="store_true")
    p.add_argument("--self-test", action="store_true")
    return p.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        synthetic_self_test()
        return 0
    if args.capture is None:
        print("capture path required (or use --self-test)", file=sys.stderr)
        return 2
    data = args.capture.read_bytes()
    if len(data) < 64:
        print("capture is too short", file=sys.stderr)
        return 2
    result = analyze(data, args)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        for key, value in result.items():
            if isinstance(value, float):
                print(f"{key:46s} {value:.4f}")
            else:
                print(f"{key:46s} {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
