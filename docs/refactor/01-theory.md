# Phase 1 — Correct the signal theory

Branch `refactor/phase1-theory`, stacked on `refactor/phase0-recon`.

## What changed and why

### Docs

- **`docs/THEORY.md`** (new) is the single source of truth. It covers:
  - the receiver chain;
  - modulation and Carson bandwidth, derived to 20–27 MHz;
  - the 48-channel plan;
  - the 4-bit I/Q decode and the ADC-fill gain rule;
  - the discriminator and its unambiguous range (the n→n+2 winding loss);
  - phase-quantisation noise;
  - the GOLDEN LUT mapping;
  - roofed de-emphasis: τ_p = 0.8162 µs, 13.4 dB roof, which fits the published NTSC
    network within 0.6 dB;
  - the audio-subcarrier trap;
  - carrier offset, AFC and clamping;
  - level normalisation;
  - threshold clicks;
  - NTSC/PAL timing;
  - a table of code constants.
- **`docs/MEASUREMENTS.md`** (new) collects upstream's hardware-measured facts with sources
  (M1–M52). Host-only and computed numbers are listed separately as *not measurements*.

### Code

| Change | Theory | Files |
|---|---|---|
| **GOLDEN LUT is generated**, and the monotone rail clamp replaces the `e7f38f2` fold-back squelch. The table is now word-for-word upstream's hardware-praised Golden Phase5 (M46). The generator also reproduces the fold-back variant exactly, for A/B. | §5.5, §10 | `tools/gen_phase5_lut.py` (new), `main/fm.bsasm`, `main/fm4.bsasm` (LUT line + header) |
| **ARC V3 is the default RX profile.** It is ADC-fill only and hardware walk-validated (M44). Persisted or unknown profiles migrate to it. | §4.3 | `main/video.c` (`RX_PROFILE_DEFAULT`) |
| **Video-coupled gain profiles disabled**: ARC v1, RANGE, RANGE V2 and FUSION feed sync or semantic-video quality into RF gain. They can no longer be cycled to, restored from NVS, or applied. The code remains until Phase 5 deletes it. | §4.3 | `main/video.c` (`rx_profile_couples_video_to_gain`) |
| **Post-demod level estimator**: sync tip S, blanking B and sync amplitude A in kHz of deviation, from the completed control window. It uses exact bucket-centre phase on the production parity and a two-pass sync slicer (tip + 400 kHz, then (S+B)/2). | §8, §9, §11 | `main/video_levels.h` (new), `tools/test_video_levels.c` (new) |
| **AFC reference = blanking level.** The old estimator was the mean instantaneous frequency (`Σcross/Σdot`), which moves with picture brightness. That is blanket DC removal. AFC AUTO stays acquisition-only and ±1.5 MHz bounded. | §8 | `main/video.c` |
| Diagnostics print S/B/A against the LUT nominal (A = 2080 kHz, B = 0) | §9 | `main/video.c` console `p`/frequency diag |
| Stale or unfounded comments fixed, with THEORY/MEASUREMENTS references: free-running PARLIO clock, half-ring TX start, 1024-entry LUT, BW40 reason, boot gain 52, AFC bound | §2.3, §2.4, §4.2, §8 | `main/video.c`, `main/rf.c`, `main/*.bsasm` |
| CI runs the new level test and the LUT check. `validate_build.py` encodes the new contract (143 checks). | — | `.github/workflows/build.yml`, `tools/validate_build.py` |

### Kept on purpose (measured upstream plumbing, not contradicted)

- MODEM_DIAG mapping, PARLIO 40 MHz RX, the Zero-EOF ring, the TX_START dump arming, the
  5-queue TX lockout and BW40 (M1–M24, M40, M48).
- The 50 ns endpoint discriminator on the XIAO board. It is the budget-limited but
  hardware-proven choice (M19, M46). The theory-correct exact-adjacent discriminator
  (§5.1/§5.2) is the FPGA's job. The XIAO BitScrambler variants (#53–#67) remain unproven.
- Pedestal 20 and "gain 2" (M29). They are now documented as VTX-specific and not
  level-normalised (§9).
- The channel table. It was already single and correct. The refusal of E6–E8/R8
  (> 5885 MHz) stays, with synthesiser reachability flagged UNVERIFIED (§3).

### What the XIAO board still cannot do (by design, documented)

- **In-path de-emphasis.** A 2-bundle LUT has no output state. THEORY §6.3 specifies an
  analog roofed shelf (series R1, shunt R2 + C) instead. Component values are for
  Phase 2 / BOARDS.md and the lab.
- **Sync-tip clamp and level normalisation.** These need arithmetic in the sample path. The
  display's input clamp plus the blanking-referenced AFC cover offset. Contrast
  mismatch is visible as A ≠ 2080 kHz and can be fixed by regenerating the LUT per VTX.
- **Click interpolation.** It needs neighbours. The clamp at least stops fold-back
  inversion.

## Removed

- The `e7f38f2` fold-back LUT from production. It is reproducible with
  `gen_phase5_lut.py --variant foldback --print`.
- The mean-frequency AFC estimator.
- The video-coupled profiles from all user-reachable paths.

## Build and checks

- ESP-IDF v6.0.2 (`espressif/idf:v6.0.2`) builds `c5vrx3.bin` at 1,116,848 B (baseline
  1,113,280). No new warnings (still the 2 pre-existing Kconfig ones).
- HP SRAM static use is 273,287 B = 85.2 % (baseline 83.7 %). The +4.6 KiB is the level
  estimator workspace. 47.6 KiB remains for the heap, which must still hold the ≈19 KiB PAL
  menu descriptor chain (AGENTS.md).
- `validate_build.py` passes 143/143. All 9 host C tests pass, including the new
  `test_video_levels`. `gen_phase5_lut.py --check`, the Trajectory v2 self-test (LUT
  unchanged) and `range_demod_bench --self-test` pass.

## Found, not fixed

- `tools/test_receiver_sync.py` fails with `ValueError: substring not found` on upstream
  `96446ed` too. It isn't in CI and parses `video.c` by string offsets. Phase 5: repair or
  delete it.

## Unverified

- The Rush Tank II Ultimate's video deviation, pre-emphasis network and audio subcarriers.
  The RTC6705 datasheet specifies none of the video parameters. The −2.08 / +4.48 MHz span
  is derived from upstream's gain choice on a different VTX.
- Whether the rail-clamped LUT looks better than the fold-back. That needs a hardware A/B;
  upstream's praise (M46) predates the fold-back.
- The level estimator on real signals. It is host-tested only (NTSC+PAL synthetic FM,
  4-bit quantised, offsets −0.8…+1.4 MHz, black/white fields, noise).
- AFC stability with the new reference (loop gain, sign) on hardware.
- ARC V3 as the boot default on a cold start at all distances. M44 covers walks started
  in the profile.

## Hardware checklist for you

Use the XIAO + DAC board (the current firmware), Rush Tank II Ultimate, NTSC unless noted.

- [ ] **Flash and boot.** The console banner appears, the RX profile shows `ARC V3 EXP`, and
      the picture locks. Also test with NVS still holding an old ARC/RANGE setting (it must
      migrate to ARC V3).
- [ ] **LUT A/B.** Compare the new clamped LUT against the previous release (fold-back) on
      the same scene, close and at the range edge. Watch for dark specks on bright edges
      (fold-back) vs white clipping specks (clamp).
- [ ] **Levels.** Run console `p` (frequency diagnostics) with the VTX on a static scene and
      record `S`, `B`, `A`. A near 2080 kHz means the LUT gain fits your VTX. Tell me the
      value if it isn't.
- [ ] **Levels vs picture.** Point the camera at something dark, then bright. `B` should stay
      within about ±150 kHz while the picture changes.
- [ ] **AFC AUTO.** Detune with the AFC offset (±500 kHz) from the RF menu and enable AUTO.
      It should converge so `B` ≈ 0 and hold. Report the direction if it runs away (sign
      error).
- [ ] **Profile cycling** (console/menu). ARC, RANGE, RANGE V2 and FUSION must never appear.
- [ ] **Walk test** close → far → close with ARC V3 default: no hunting, and the gain
      trajectory is similar to M44.
- [ ] **PAL.** If the Tank II can switch to PAL (camera), repeat the Levels check with PAL.
- [ ] (Later, for §6.4) A luma step or multiburst from the camera, so we can fit the
      Tank II's pre-emphasis from an I/Q capture.
