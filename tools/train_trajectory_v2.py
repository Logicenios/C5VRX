#!/usr/bin/env python3
"""Generate and validate the C5VRX Trajectory v2 weak-signal demod LUT.

Realtime state is intentionally limited to the C5 10-bit address budget:

    prev Phase5 (5) | middle raw-Q bit0 (1) | current Phase5[4:1] (4)

For every raw Q4/I4 triple, the training target is:

    d0 = wrap(phi_middle - phi_previous)
    d1 = wrap(phi_current - phi_middle)
    target = map_to_cvbs(d0 + d1)

The d0+d1 sum is DELIBERATELY NOT WRAPPED AGAIN.  That is the entire point:
preserve the +/-2pi branch information that a 50 ns endpoint discriminator
loses before 40 -> 20 MS/s reduction.

--self-test is dependency-free and runs in CI.
--write regenerates main/fm_traj.bsasm and main/trajectory_v2_lut.h and
requires NumPy because the exhaustive 256^3 geometry pass is intentionally
kept offline.
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
    q = s4(byte & 0x0F) * 64.0 + (31.5 if s4(byte & 0x0F) >= 0 else -31.5)
    i = s4((byte >> 4) & 0x0F) * 64.0 + (31.5 if s4((byte >> 4) & 0x0F) >= 0 else -31.5)
    # Match bucket centres used by the historical Q4 model exactly.
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
    return phase5(previous) | ((middle & 1) << 5) | ((phase5(current) >> 1) << 6)


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
    expected = "662222820f078a17d69efc7392958aa95634a055175ce45678d3d637e70f3807"
    assert digest == expected, f"Trajectory v2 table drift: {digest}"

    # Spot-check address semantics across quadrant/sign boundaries.
    for p, m, c in ((0x77, 0x78, 0x88), (0xF7, 0x08, 0x18),
                    (0x11, 0xF0, 0x0F), (0x87, 0x80, 0x70)):
        a = trajectory_address(p, m, c)
        assert 0 <= a < 1024
        assert (a & 31) == phase5(p)
        assert ((a >> 5) & 1) == (m & 1)
        assert ((a >> 6) & 15) == (phase5(c) >> 1)

    print(
        "Trajectory v2 self-test passed: "
        f"1024 states, {len(set(dac))} DAC levels, "
        f"confidence {min(confidence)}..{max(confidence)}, sha256={digest[:16]}"
    )


def regenerate() -> tuple[list[int], list[int], list[int]]:
    try:
        import numpy as np
    except ImportError as exc:
        raise SystemExit("--write requires NumPy") from exc

    phi = np.array([phase_rad(b) for b in range(256)], dtype=np.float64)
    p5 = np.array([phase5(b) for b in range(256)], dtype=np.int32)
    counts = np.zeros(1024, dtype=np.int64)
    sums = np.zeros(1024, dtype=np.float64)
    sums2 = np.zeros(1024, dtype=np.float64)

    m_grid, c_grid = np.indices((256, 256), dtype=np.int32)
    m_flat = m_grid.reshape(-1)
    c_flat = c_grid.reshape(-1)
    middle_hint = m_flat & 1
    curr4 = p5[c_flat] >> 1

    def wrap_np(x):
        return (x + math.pi) % TAU - math.pi

    for p in range(256):
        d0 = wrap_np(phi[m_flat] - phi[p])
        d1 = wrap_np(phi[c_flat] - phi[m_flat])
        summed = d0 + d1  # DO NOT wrap this sum.
        phase8 = np.where(
            summed * 256.0 / TAU >= 0,
            np.floor(summed * 256.0 / TAU + 0.5),
            -np.floor(-summed * 256.0 / TAU + 0.5),
        ).astype(np.int32)
        n = phase8 * 3
        correction = np.where(n < 0, -((-n + 2) // 4), (n + 2) // 4)
        target = np.clip(20 + correction, 0, 63).astype(np.int32)
        address = p5[p] | (middle_hint << 5) | (curr4 << 6)
        counts += np.bincount(address, minlength=1024)
        sums += np.bincount(address, weights=target, minlength=1024)
        sums2 += np.bincount(address, weights=target * target, minlength=1024)

    denom = np.maximum(counts, 1)
    mean = sums / denom
    dac = np.where(mean >= 0, np.floor(mean + 0.5), -np.floor(-mean + 0.5)).astype(np.int32)
    variance = np.maximum(0.0, sums2 / denom - mean * mean)
    std = np.sqrt(variance)
    confidence = np.clip(np.floor(255.0 * (1.0 - np.minimum(std, 32.0) / 32.0) + 0.5), 0, 255).astype(np.int32)

    words = dac.copy()
    words[:256] |= p5 << 8
    return words.tolist(), dac.tolist(), confidence.tolist()


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
 * Address: prev_phase5 | (middle_q_lsb << 5) | ((current_phase5 >> 1) << 6)
 * The DAC target is the uniform-geometry mean of exact adjacent d0+d1 with
 * NO second wrap. Confidence is inverse target spread and is supervisory only.
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
