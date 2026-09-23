# Measured facts (upstream hardware evidence)

These are facts measured on physical hardware by upstream (maintainer `Twotoz`). They
should not be "fixed" without new contrary measurements (see
[`THEORY.md`](THEORY.md)).

Unless a row says otherwise, the setup was:
- board: Seeed XIAO ESP32-C5, chip rev v1.0;
- RF: Wi-Fi ch173 = 5865 MHz (Band A1);
- ESP-IDF 6.0.1 (C5VRX-2 era) or 6.0.2 (C5VRX-3 era);
- a single NTSC camera + VTX on the bench.

Source links point at `docs/`, at `legacy/…/measurements/`, or at the GitHub item
(`#N` = `https://github.com/Twotoz/C5VRX/issues/N` or `/pull/N`).

Evidence quality:
- **Q** = quantitative (numbers recorded);
- **S** = subjective visual observation;
- **H** = host analysis of a real hardware capture (the capture is hardware, the statistic is offline).

Rows whose numbers were only computed or simulated are listed at the end under
*not measurements*.

## RF writer, modem diagnostic bus, sample rates

| # | Fact | Q | Conditions | Source |
|---|---|---|---|---|
| M1 | RF dump writer armed once (DUMP_PTR_MODE[24:17]=0x00060000 TX_START trigger select, DUMP_CTRL[17] dump-first, [31] enable, no START) runs autonomously at **≈79.97 MS/s** | Q | producer only, MAC TX queues disabled | continuous-iq-findings.md:8-16; PR #2 |
| M2 | Soak: 10,000 physical wraps, 1 producer start, 0 rearms, 0 triggers; no `DUMP_CTRL` writes on normal wraps | Q | producer-only soak | continuous-iq-findings.md:19-30; hardware-test.md §3 |
| M5 | Reserving only the first 64 KiB dump bank → CPU lockup; both `0x40830000-0x4084ffff` banks had to be excluded from the heap in that design | Q | SRAM_USAGE=2 era | continuous-iq-findings.md:43-46 |
| M6–M10 | MAC-owned dump SRAM is **not live-readable**: CPU reads zeros, AHB-GDMA copies unchanged over 300 µs, APM shows no exception. The writer keeps ≈79.96 MS/s. | Q | several ownership states | continuous-iq-findings.md:48-120 |
| M11 | All 32 MODEM_DIAG outputs looped back: signals 0–19 toggle with VTX off, all 32 with VTX on; strongest VTX dependence on 6–9 and 16–19 | Q | GPIO-matrix loopback | continuous-iq-findings.md:138-146 |
| M12 | **DIAG[6:9] = Q[9:6], DIAG[16:19] = I[9:6]** (top nibble of signed 10-bit I/Q); no swap, reversal or inversion improves the match | Q | VTX off and on | continuous-iq-findings.md:162-168; hardware-test.md §4 |
| M14 | Bit match vs. the dump ring: VTX on 94.75 % (718/900 bytes), off 95.50 % (822/900); RF 79.994 MS/s; VTX-on ring uses all 16 nibble values | Q | CPU GPIO polling (≈4.5 MS/s, asynchronous) | continuous-iq-findings.md:171-181 |
| M16 | PARLIO RX on the Q4/I4 lanes captures a bit-perfect sequence of **every second** native modem sample | Q | bounded capture | continuous-iq-findings.md:187-189 |
| M17 | PARLIO RX tops out at **≈40 MS/s** even when 80 MHz is requested | Q | | continuous-iq-findings.md:188-190 |
| M18 | An RX-attached BitScrambler cannot sustain the input cadence | Q | | continuous-iq-findings.md:204-205 |
| M19 | A TX-attached BitScrambler consumes 2 input bytes per 20 MHz output byte without FIFO underrun | Q | bounded full-duplex | continuous-iq-findings.md:205-208 |
| M20/M21 | BitScrambler LUT address map verified by oracle (4000/4000); production 1024-entry LUT matches the CPU reference 3998/3999 (the miss is at the trailing pipeline edge) | Q | bounded, TX 20 MS/s | continuous-iq-findings.md:215-229 |
| M24 | A LUT loaded before the PARLIO TX transaction is **not** used by the active run; a LUT embedded in the program is byte-exact | Q | IDF 6.0.1 | image-quality.md:72-77 |

## Transport and output

| # | Fact | Q | Conditions | Source |
|---|---|---|---|---|
| M22 | First live locked NTSC picture, recognisable moving image with visible static | S | commit 69f52c3, 2026-09-09 | continuous-iq-findings.md:262-266 |
| M39 | Linear80 BitScrambler loopback 32,764/32,768 bytes (tail 10 → exact); stock DMA-EOF finite TX times out ≈1 s at 40/80 MHz | Q | RF off, CPU 160 | legacy/c5vrx2/measurements/pr16-linear80/hardware160-first-result.md, eof-sweep.md |
| M40 | **PARLIO TX 8-bit at 40 MHz is byte-exact on the pads (4096/4096) with and without the Phase5 BitScrambler. Direct TX at 48, 60 and 80 MHz, and every BitScrambler variant at 80 MHz, fail with TX FIFO-empty.** CPU 240 and 64-B bursts do not help. | Q | RF off, IDF 6.0.1 | legacy/c5vrx2/measurements/pr16-linear80/pad-capture.md; #16, #17 |
| M38 | 5-bundle midpoint BitScrambler core at TX 40 MHz → black picture | S | 2026-09-13 | PR #16 comment; commit 546672e |
| M47 | Ring aligned to 4092-B GDMA nodes (PR #8): horizontal layer jitter unchanged or worse, thicker layers | S | live A/B | PR #8 comment 2026-09-12 |
| M48 | Descriptor `suc_eof` cleared on all ring nodes (Zero-EOF): the periodic vertical jump / top-bottom black bar disappears, together with wrap-related jagged edges | S | live, C5VRX-3 | #21 closing comment; PR #24 |
| M49 | True-40 adjacent demod (PR #18): "much worse" live, with higher background static and sporadic large tears | S | live | #17 comment 2026-09-13; PR #18 comments |
| M50 | Menu GDMA descriptor chain (66–76 KiB contiguous) after Wi-Fi start → `ESP_ERR_NO_MEM` → reboot | Q | COM10 | PR #52 comment 2026-09-22 |
| M51 | `bitscrambler_reset()` on the C5 **RX** channel times out (`in_idle` never asserts before a transaction). The dual RX+TX BitScrambler pipeline gave a black picture with the ring stuck at 0xFF (Phase5 = 31). | Q | ESP32-C5 ECO2 | PR #65 comments 2026-09-23 |

## Demodulator and picture

| # | Fact | Q | Conditions | Source |
|---|---|---|---|---|
| M25 | Full-Q4/I4 Phase5 vs Q3/I2: locked, more colour, visibly less static | S | 2026-09-09 | image-quality.md:69-70 |
| M26 | Frozen raw Q4 snapshot, VTX on: carrier offset +0.071 MHz (even samples) / +0.198 MHz (odd) | H | 16 KiB, ≈1 s after start | image-quality.md:99-115 |
| M28 | Centroid output mapping (13 → 34 codes): no material change in static or grey cast | S | | image-quality.md:126-133 |
| M29 | Output gain: "gain 1" (0.75×) puts the sync tip ≈ code 1 and burst below the TV's chroma threshold (coloured static); **"gain 2" (1.5×, the current 3/4·Δφ₈ scale) puts the sync tip at code 0 with correct hues**; snow unchanged by gain | S | 2026-09-10 | image-quality.md:138-153; commit 6b931fb |
| M33 | **BW20 vs BW40:** BW20 loses resolution and destabilises chroma | S | 2026-09-12; scene/VTX not recorded | static-reduction-and-filtering.md:104-107; fix-cvbs-jitter-and-static.md:79-89 |
| M46 | The "Golden Phase5" build (full Q4/I4, uniform phase5, centroid LUT with **rail clamp**, 50 ns, POS edge) is the best picture upstream reported: "fantastic, small teeth, almost no static" | S | 2026-09-13 | PR #18/#19 comments |

## Gain chain (ADC fill)

| # | Fact | Q | Conditions | Source |
|---|---|---|---|---|
| M42 | Far: at G62 the Q4 stream is dead (P≈1, Q_phase 0, origin 1000 ‰). Within the top RF stage G62→G81 only reaches P2/Q3/origin 822 ‰. With the full vendor table, **G76–G79 recover coherent Q4** (P 9–17, Q 74–99, origin 62→0 ‰). | Q | 2026-09-22 | pre-q4-lab.md §2, §3; PR #56, #57 |
| M43 | Medium: gain response is **non-monotone**. G62 P17/Q100; G63 P1/Q0/origin 937; G64 P17/Q95; G65 P32/Q100; G66 clip 257 ‰; G68 clean again (bb/fine code transitions). | Q | 2026-09-22 | pre-q4-lab.md §2 |
| M43b | Close: G62 clips at 627 ‰; G81 clips at 957 ‰; the useful region is ≈G46–47 | Q | 2026-09-22 | pre-q4-lab.md; PR #57 |
| M44 | ARC V3 live walks: medium→extra-close G62/68 → G54 → G50 → G46 → G38 → G35 → G31 → G14/17; close→far G16 → G54 → G74/73 → G78 → G79 → G81. Temporal median filtering removed the hunting seen with single 50 ms windows. | Q | live walk | PR #58 comments |
| M45 | Gain changes "normally settle for 500 ms". **Design statement, no recorded measurement**; UNVERIFIED. | — | | arc-receive-chain.md:181-183 |
| M52 | Turning off the PARLIO/DAC TX and holding the DAC pads low ("self-noise" A/B) gives **no repeatable raw-Q4 improvement** | Q | weak/medium runs; strong runs clipped and excluded | pre-q4-lab.md §1; PR #56 |

## This fork's measurements

| # | Fact | Q | Conditions | Source |
|---|---|---|---|---|
| M53 | Waveshare C5-Zero on the new MODEM_DIAG pads {0,1,4,5,6,7,8,9} captures a coherent carrier. ARC V3 settles to LOCK (Q4=TARGET) at **G43**: P_median 25–29, Q_phase 99–100 %, clip 0 %, origin 0 %, endpoint winding 0 %. Zero transport faults. | Q | Rush Tank II Ultimate at **25 mW on A1**, bench distance, external IPEX antenna, IDF 6.1.0, rev v1.0 | console `d`/`p`, 2026-09-23 |
| M54 | Post-demod levels (`video_levels.h`): **sync amplitude A = 809 / 972 kHz** (two windows), sync tip S ≈ −1.0 MHz, blanking B = −195 / −50 kHz. The AFC blanking estimate was −209 → −141 kHz. That is **≈ 0.4–0.47× the 2080 kHz the GOLDEN LUT assumes** (THEORY §2.2/§5.5). On the XIAO DAC this VTX would give a sync of only ~8–9 codes and low contrast, so level normalisation (THEORY §9) is needed. | Q | same; estimator host-verified only; 50 ns endpoint phase, 4-bit | console `d`, 2026-09-23 |
| M55 | Upstream's semantic sync / standard detector reports `syncQ=0`, standard UNKNOWN on the same signal. Its thresholds are fixed in LUT-code units, so a VTX with smaller deviation fails them. | Q | same | console `d`, 2026-09-23 |
| M56 | Phase 3 firmware (PARLIO RX clock output on GPIO10 as FPGA strobe) still locks: ARC V3 G45, P 25–32, Q 98–99 %, clip/origin 0. Levels valid: A = **1514 / 1531 kHz**, B = −340 / −42 kHz, AFC −171 / −217 kHz. A differs from M54 (809–972 kHz) in the same bench setup; the cause is unknown (see P1). | Q | Tank II 25 mW A1, bench, C5-Zero | console `d`, 2026-09-23 |

## Pending measurements (to do in the lab)

Open items collected across phases. Run them when the hardware is available, then move
each result into a numbered row above.

| ID | What | Why | From |
|---|---|---|---|
| P1 | Level estimator stability: record S/B/A over ~1 min on a static scene; then dark vs bright scene | A varied 809–972 kHz (M54) and later 1514–1531 kHz (M56) in the same setup; B must not move with picture (THEORY §8) | Phase 1/2 |
| P2 | Levels and lock at range (walk test, several distances) | M53/M54 are bench-range only | Phase 2 |
| P3 | AFC AUTO convergence with the blanking reference (detune ±500 kHz) | sign/loop gain untested on hardware | Phase 1 |
| P4 | Spectrum/SDR check at boot, channel change and after fresh-PHY-cal (`K`) | receive-only audit T1–T3; calibration drives internal TX tones (recon §3) | Phase 0/2 |
| P5 | Antenna polarity cross-check: IPEX removed, onboard vs external | confirms Waveshare's GPIO26 statement independently | Phase 2 |
| P6 | Tank II pre-emphasis fit (luma step / multiburst capture) | THEORY §6.4; de-emphasis constants | Phase 1 |
| P7 | Channels > 5885 MHz (E6–E8, R8) and L band tuning | THEORY §3 reachability | Phase 1 |
| P8 | Board current/temperature of the C5-Zero | "gets warm"; expected, not measured | Phase 2 |
| P9 | FPGA-link electrical items L3.1–L3.6 (strobe, skew, termination, UART, scan) | docs/FPGA_LINK.md §5 | Phase 3 |
| P10 | GOLDEN clamped vs fold-back LUT A/B, and XIAO boot on IDF 6.1 | needs the DAC board | Phase 1/2 |

## Levels and hardware network (computed, not measured)

The resistor network is DAC b0..b5 on XIAO D4..D9 = GPIO 23, 24, 11, 12, 8, 9 through
8.2k / 3.9k / 2.0k / 1.0k / 470 / 240 Ω to VIDEO, with 200 Ω to ground
(hardware-test.md). The expected loaded levels (code 0 ≈ 0 V, 18–20 ≈ 0.3 V,
62–63 ≈ 1.0 V into 75 Ω) are **computed**. No scope capture exists (lab item).

## Not measurements

These look like data but are host, simulated, or computed. Don't cite them as hardware facts.

- Phase-error figures (9.52°/25.63° → 3.27°/5.62°).
- Trajectory MAE and hard-error rates (15.962/25.033 % → 12.528/21.800 %; 3.34 codes / 5.06 %).
- DAC-level counts (13/15/28/34/38).
- The synthetic linear80 spectrum.
- The "true-40 MAE ≈ 2.6 codes" model.
- Winding-loss rates 8.351 % / 0.285 % (M30, H: host statistic on one real capture).
- The issue #11 H-sync jitter numbers (bounded *replay*, configured rates, no external
  timebase).
