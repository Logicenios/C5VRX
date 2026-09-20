#!/usr/bin/env python3
"""Generate and validate the C5VRX Trajectory v2 weak-signal demod LUT.

Realtime state is intentionally limited to the C5 10-bit address budget:

    prev Phase5 (5) | middle raw-I sign (1) | current Phase5[4:1] (4)

For every physical-FM training triple:

    d0 = wrap(phi_middle - phi_previous)
    d1 = wrap(phi_current - phi_middle)

Strong-Q4 target = map_to_cvbs(d0 + d1)
Weak-Q4 target   = map_to_cvbs(clean_local_d0 + clean_local_d1)

The adjacent sum is DELIBERATELY NOT WRAPPED AGAIN. Strong samples teach the
raw exact-adjacent discriminator; weak samples use a deterministic clean
trajectory holdover prior instead of learning a noisy near-origin click.

--self-test is dependency-free and runs in CI.
--write deterministically regenerates main/fm_traj.bsasm and
main/trajectory_v2_lut.h from the pinned physical-FM prior.
"""
from __future__ import annotations

import argparse
import hashlib
import math
import re
import sys
from pathlib import Path
from typing import Sequence

ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "main" / "fm_traj.bsasm"
HEADER = ROOT / "main" / "trajectory_v2_lut.h"
TAU = 2.0 * math.pi


def iround(x: float) -> int:
    return int(math.floor(x + 0.5)) if x >= 0.0 else -int(math.floor(-x + 0.5))


def s4(v: int) -> int:
    return v - 16 if v & 8 else v


def phase_rad(byte: int) -> float:
    # Match bucket centres used by the historical full-Q4 model exactly.
    qc = byte & 0x0F
    ic = (byte >> 4) & 0x0F
    q = qc * 64.0 + 31.5
    i = ic * 64.0 + 31.5
    if q >= 512.0:
        q -= 1024.0
    if i >= 512.0:
        i -= 1024.0
    return math.atan2(q, i)


def phase5(byte: int) -> int:
    return iround(phase_rad(byte) * 32.0 / TAU) & 31


def wrap(x: float) -> float:
    while x > math.pi:
        x -= TAU
    while x <= -math.pi:
        x += TAU
    return x


def scale_rad(rad: float) -> int:
    phase8 = iround(rad * 256.0 / TAU)
    n = phase8 * 3  # production gain=2 => (gain + 1)
    if n < 0:
        correction = -((-n + 2) // 4)
    else:
        correction = (n + 2) // 4
    return max(0, min(63, 20 + correction))


def trajectory_address(previous: int, middle: int, current: int) -> int:
    return phase5(previous) | (((middle >> 7) & 1) << 5) | ((phase5(current) >> 1) << 6)


def parse_lut_words(text: str) -> list[int]:
    match = re.search(r"^lut (.*)$", text, re.MULTILINE)
    if not match:
        raise AssertionError("fm_traj.bsasm has no embedded LUT")
    return [int(v) for v in match.group(1).split()]


def parse_header_array(text: str, name: str) -> list[int]:
    match = re.search(
        rf"static const uint8_t {re.escape(name)}\[1024\]\s*=\s*\{{(.*?)\}};",
        text,
        re.DOTALL,
    )
    if not match:
        raise AssertionError(f"missing {name}[1024]")
    return [int(v) for v in re.findall(r"\d+", match.group(1))]


def instruction_blocks(text: str) -> dict[str, list[str]]:
    blocks: dict[str, list[str]] = {}
    current: list[str] | None = None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip().rstrip(",")
        if not line or line.startswith(("cfg ", "lut ")):
            continue
        if line.endswith(":"):
            current = []
            blocks[line[:-1]] = current
        elif current is not None:
            current.append(line)
    return blocks


def self_test() -> None:
    asm = ASM.read_text()
    header = HEADER.read_text()
    words = parse_lut_words(asm)
    dac = parse_header_array(header, "c5vrx_trajectory_v2_dac")
    confidence = parse_header_array(header, "c5vrx_trajectory_v2_confidence")

    assert len(words) == 1024
    assert len(dac) == 1024
    assert len(confidence) == 1024
    assert all(0 <= v <= 63 for v in dac)
    assert all(0 <= v <= 255 for v in confidence)
    assert len(set(dac)) >= 32, "trajectory path collapsed output resolution"

    # Low six bits are the live DAC target. The first 256 dual-purpose words
    # also expose full-Q4 -> Phase5 in bits 8..12 for the prime/current lookup.
    for idx, word in enumerate(words):
        assert (word & 63) == dac[idx], (idx, word, dac[idx])
        if idx < 256:
            assert ((word >> 8) & 31) == phase5(idx), idx
        else:
            assert (word >> 6) == 0, idx

    blocks = instruction_blocks(asm)
    assert set(blocks) == {"prime_lookup", "prime_store", "trajectory", "emit"}
    assert blocks["prime_lookup"][-1] == "read 16"
    assert blocks["prime_store"][-1] == "read 16"

    # Physical realtime contract: after priming, exactly trajectory -> emit.
    # trajectory is a pure address/state bundle; emit owns one read, one write
    # and the loop jump. Adding a third steady-state bundle would underrun.
    assert not any(op.startswith(("read ", "write ", "jmp ")) for op in blocks["trajectory"])
    assert blocks["emit"][-3:] == ["read 16", "write 16", "jmp trajectory"]
    assert "cfg eof_on downstream" in asm
    assert "cfg trailing_bytes 0" in asm
    assert "cfg lut_width_bits 16" in asm
    assert "NOT wrapped again" in asm or "NOT re-wrapped" in asm or "NOT WRAPPED" in asm.upper()

    # Guard the exact generated tables. Any intentional retraining must use
    # --write and update this digest in the same reviewed change.
    packed = bytes(dac) + bytes(confidence)
    digest = hashlib.sha256(packed).hexdigest()
    expected = "15e57fe6e571da29acce82c6824e276a306faae3ed54d4f4a5984c9f3d269f86"
    assert digest == expected, f"Trajectory v2 table drift: {digest}"

    # Spot-check address semantics across quadrant/sign boundaries.
    for p, m, c in ((0x77, 0x78, 0x88), (0xF7, 0x08, 0x18),
                    (0x11, 0xF0, 0x0F), (0x87, 0x80, 0x70)):
        a = trajectory_address(p, m, c)
        assert 0 <= a < 1024
        assert (a & 31) == phase5(p)
        assert ((a >> 5) & 1) == ((m >> 7) & 1)
        assert ((a >> 6) & 15) == (phase5(c) >> 1)

    print(
        "Trajectory v2 self-test passed: "
        f"1024 states, {len(set(dac))} DAC levels, "
        f"confidence {min(confidence)}..{max(confidence)}, sha256={digest[:16]}"
    )


def _xorshift32(state: int) -> tuple[int, float]:
    state ^= (state << 13) & 0xFFFFFFFF
    state ^= state >> 17
    state ^= (state << 5) & 0xFFFFFFFF
    state &= 0xFFFFFFFF
    return state, state / 4294967296.0


def _js_round(x: float) -> int:
    # Match Math.round used when the canonical table was trained.
    return math.floor(x + 0.5)


def regenerate() -> tuple[list[int], list[int], list[int]]:
    """Rebuild the pinned physics prior.

    Strong Q4 triplets follow their exact raw adjacent discriminator. Weak
    triplets use the known clean local FM trajectory as a small PLL/holdover
    prior. This prevents impossible uniform-Q4 jumps from dominating the LUT.
    """
    golden_words = parse_lut_words((ROOT / "main" / "fm.bsasm").read_text())
    phases = [phase_rad(b) for b in range(256)]
    phases5 = [phase5(b) for b in range(256)]
    powers = []
    for b in range(256):
        i, q = s4((b >> 4) & 0x0F), s4(b & 0x0F)
        powers.append(i * i + q * q)

    count = [0] * 1024
    sums = [0.0] * 1024
    sums2 = [0.0] * 1024
    state = 0x314159
    spare = None

    def uniform() -> float:
        nonlocal state
        state, value = _xorshift32(state)
        return value

    def gaussian() -> float:
        nonlocal spare
        if spare is not None:
            value, spare = spare, None
            return value
        u = max(1e-12, uniform())
        v = uniform()
        radius = math.sqrt(-2.0 * math.log(u))
        angle = TAU * v
        spare = radius * math.sin(angle)
        return radius * math.cos(angle)

    def quant(phi: float, amplitude: float, sigma: float) -> int:
        i = amplitude * math.cos(phi) + sigma * gaussian()
        q = amplitude * math.sin(phi) + sigma * gaussian()
        ii = max(-8, min(7, _js_round(i))) & 0x0F
        qq = max(-8, min(7, _js_round(q))) & 0x0F
        return (ii << 4) | qq

    for _ in range(1_200_000):
        phi0 = (uniform() * 2.0 - 1.0) * math.pi
        slope = (uniform() * 2.0 - 1.0) * 0.98
        accel = (uniform() * 2.0 - 1.0) * 0.34
        d0 = max(-1.20, min(1.20, slope - accel * 0.5))
        d1 = max(-1.20, min(1.20, slope + accel * 0.5))

        amplitude = 1.6 + uniform() * 5.3
        if uniform() < 0.10:
            amplitude = 0.45 + uniform() * 2.0
        sigma = uniform() * 1.15

        p = quant(phi0, amplitude, sigma)
        m = quant(wrap(phi0 + d0), amplitude, sigma)
        c = quant(wrap(phi0 + d0 + d1), amplitude, sigma)

        clean_target = scale_rad(d0 + d1)
        raw_exact = scale_rad(
            wrap(phases[m] - phases[p]) + wrap(phases[c] - phases[m]))
        strong = min(powers[p], powers[m], powers[c]) >= 32
        target = raw_exact if strong else clean_target

        address = phases5[p] | (((m >> 7) & 1) << 5) | ((phases5[c] >> 1) << 6)
        count[address] += 1
        sums[address] += target
        sums2[address] += target * target

    dac = [20] * 1024
    confidence = [0] * 1024
    for address in range(1024):
        if count[address]:
            mean = sums[address] / count[address]
            variance = max(0.0, sums2[address] / count[address] - mean * mean)
            std = math.sqrt(variance)
            dac[address] = max(0, min(63, iround(mean)))
            confidence[address] = max(
                0, min(255, iround(255.0 * (1.0 - min(std, 24.0) / 24.0))))
        else:
            prev = address & 31
            current4 = (address >> 6) & 15
            c0 = current4 << 1
            c1 = c0 | 1
            d0 = golden_words[(prev << 5) | c0] & 63
            d1 = golden_words[(prev << 5) | c1] & 63
            dac[address] = iround((d0 + d1) * 0.5)

    words = list(dac)
    for raw in range(256):
        words[raw] |= phases5[raw] << 8
    return words, dac, confidence


def write_generated() -> None:
    words, dac, confidence = regenerate()

    asm = ASM.read_text()
    asm = re.sub(r"^lut .*$", "lut " + " ".join(map(str, words)), asm, count=1, flags=re.MULTILINE)
    ASM.write_text(asm)

    def rows(values: list[int]) -> str:
        return "\n".join(
            "    " + ", ".join(map(str, values[i:i + 16])) + ","
            for i in range(0, len(values), 16)
        )

    header = f"""/* Generated Trajectory v2 reference tables.
 * Source model: tools/train_trajectory_v2.py
 * Address: prev_phase5 | (middle_i_sign << 5) | ((current_phase5 >> 1) << 6)
 *
 * Strong triplets target raw exact-adjacent d0+d1. Weak triplets target the
 * clean local FM trajectory as a PLL-lite holdover prior. d0+d1 is never
 * re-wrapped. Confidence is inverse target spread and is supervisory only.
 */
#pragma once
#include <stdint.h>

static const uint8_t c5vrx_trajectory_v2_dac[1024] = {{
{rows(dac)}
}};

static const uint8_t c5vrx_trajectory_v2_confidence[1024] = {{
{rows(confidence)}
}};
"""
    HEADER.write_text(header)
    digest = hashlib.sha256(bytes(dac) + bytes(confidence)).hexdigest()
    print(f"regenerated Trajectory v2: {len(set(dac))} DAC levels, sha256={digest}")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--write", action="store_true")
    return p.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.write:
        write_generated()
    if args.self_test or not args.write:
        self_test()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
