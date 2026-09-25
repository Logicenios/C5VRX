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
| M57 | Tang Nano 20K: `make prog-pattern` 720p colour bars are displayed by the user's monitor at 720p60, at 720p50 (S1) and in DVI mode (S2). | Q | Tang Nano 20K, HDMI monitor | user report, 2026-09-23 |
| M58 | GW2AR-18 rPLL dynamic dividers: **IDIV = 64 − IDSEL, FBDIV = 64 − FBDSEL**. All 1,557 locked points of a full 64×64 IDSEL/FBDSEL sweep match 27·FBDIV/IDIV MHz within 0.1 %. | Q | `fpga/bringup/pll_probe.v`, ODIV 8, CLKOUT counted for 10 ms against the 27 MHz crystal, BL616 UART log | 2026-09-23 |
| M59 | Cascaded rPLLs retuned at run time: 27×11/2×5/2 = **371.2499 MHz** and 27×50/7×25/13 = **370.8790 MHz** (720p59.94 TMDS), both within 0.3 ppm of target (crystal-relative, count resolution). Relock after reset takes 114–155 µs (A) and ~140 µs (B), repeatable over ~140 alternating switches. 3 readings were invalidated by the probe's own gate/epoch handshake race; lock times were normal in those runs. | Q | `fpga/bringup/pll_cascade_probe.v`, B CLKOUTD /8 counted for 100 ms | 2026-09-23 |
| M60 | Embedded SDRAM at the **74.25 MHz** pixel clock (clock out through ODDR, inverted): with CAS latency 2 the first word is captured **4 clocks** after READ, on both the rising and the falling capture edge (0 errors in 16,384 words each). The zero-delay model predicts 3; pad and board delays add one clock. Latency 2/3/5/6 fail. CL 3 is marginal (548–626 wrong words at latency 5) and is not used. **Soak:** CL 2, latency 4, both edges, 24,462 passes of 16,384 words each (400.8 M words) in 60 s: 0 errors. | Q | `fpga/bringup/sdram_probe.v`, pattern over all banks/rows, seed changed per pass | 2026-09-24 |
| M61 | **Pad input registers do not work** with this toolchain on the GW2AR-18: with `nextpnr --vopt ireg_in_iob`, a floating header pin with PULL_MODE=UP reads a constant **0** through the packed IOLOGIC input register. The same design without the option reads 1 (pull-up) and 0 (pull-down) correctly. In the full design this silently disabled S1/S2 (M62), and it would have zeroed the C5 sample link and the UART RX. Capture now uses fabric flip-flops. | Q | `fpga/bringup/iob_probe.v`, pins 42 (up) / 41 (down), OSS CAD Suite 2026-09-23 | 2026-09-24 |
| M62 | Full receiver on the Tang Nano 20K (no C5 attached): 720p output, OSD banner "C5 link lost / NO C5 LINK", LED0 (HDMI PLLs) and LED1 (SDRAM ready) on. The control CPU runs: GET_SETTINGS every 500 ms, all frames valid on the debug mirror (`bringup/link_sniff.py`). S1/S2 had no effect because of M61. | Q | user report + `/dev/ttyUSB1` capture | 2026-09-24 |
| M63 | Full design, 5-minute link capture while the menu was used (FPGA_DEBUG frames): the PLLs are stable in steady state in every mode (59.94 Hz for 206 s and 50 Hz for 46 s with no restart). But right after a 50 → 59.94 retune, PLL B's LOCK dropped twice within ~1 s, and the old `clk_gen` restarted the whole pixel domain on each drop: the "screen goes black and comes back" the user saw. A separate probe shows 0 LOCK drops in 180 s in the 60/50 setting. Fix: LOCK debouncing (2 ms stable before release, 1 ms low before restart), tested with a chattering-LOCK model (`sim/tb_clkgen.v`). | Q | `fpga/bringup/link_sniff.py` on the debug mirror, `bringup/lock_probe.v` | 2026-09-24 |
| M64 | With LOCK debouncing: 6-minute capture while the user switched Standard NTSC/PAL several times, tried Force 60 and left it at 59.94 Hz. 7 restarts = 7 rate changes (cause "mode change" each time, none from LOCK), 59.94 Hz stable for 232 s. The user reports one blink per change and no further blanking; S1/S2 menu, channel stepping and Save all work. | Q | `bringup/link_sniff.py` FPGA_DEBUG frames + user report | 2026-09-24 |
| M65 | First C5 → FPGA link bring-up (C5-Zero on its own USB, grounds wired, breadboard): wiring self-test passes on all 9 lines, both UART directions work, STROBE 40.00024 MHz (+6 ppm against the Tang Nano crystal). Raw capture: data lines barely toggle (bits 0–4 high 0–12 % of the time) while the C5 itself captures a normal I/Q stream on both of its sample edges from the same pads. Cause: **33 kΩ** series resistors instead of 33 Ω (RC ≈ 0.2–0.3 µs against 12.5 ns bits). | Q | `bringup/link_sniff.py --capture`, `bringup/cap_analyze.py`, C5 console `d`/`e` | 2026-09-24 |
| M66 | With the series resistors removed: link data clean (bits 42–58 % high, 0 % clicks, edge-placement errors 1–3 %). Rush Tank II Ultimate on A1: **PAL**, sync period **64.00 µs**, carrier ~0.6 MHz below tune (blanking −0.60 MHz, sync tip −1.39 MHz, picture to about +1.45 MHz; sync amplitude ≈ 0.8 MHz, consistent with M54). FPGA `video_timing` did not lock: its bootstrap slicer (running minimum + 400 kHz) released the minimum by 1 LSB per sample (~0.78 MHz per line), which lifted the slice above blanking at this carrier offset. Released 16× more slowly, it locks on the recorded signal (`fpga/sim/vectors/tank2_pal_10lines.hex`, `make -C fpga/sim real`). | Q | `bringup/c5_ring_dump.py`, RTL replay | 2026-09-24 |
| M67 | Block RAM 36-bit mode: the 256 × 25 phase table read from one 36-bit-wide single-port block RAM, and from an 18-bit + 9-bit pair, matches the same table in LUT logic: **0 mismatches** at 27 M reads/s (both modes). The 36-bit mode is fine. | Q | `fpga/bringup/bram_probe.v` | 2026-09-24 |
| M68 | **DSP multipliers return wrong products in signed mode** with the open-source Gowin flow: random operands, checked against a serial shift-add reference (0 errors in RTL simulation). signed18×signed18, signed18×unsigned17, signed9×signed9 and signed9×unsigned8 each fail on ~3–5 % of products; unsigned×unsigned (18 and 9 bit) is exact. This made fm_frontend and video_timing produce garbage on hardware (tip +28 MHz, 25 k false H syncs/s) while the RTL is bit-exact. Fix: a synthesis-time techmap rewrites every signed `$mul` as an unsigned multiply plus sign corrections (`fpga/tools/smul_map.v`). With it, all six forms show **0 mismatches** at ~6.75 M products/s on hardware. | Q | `fpga/bringup/dsp_probe.v` | 2026-09-24 |
| M69 | **STROBE double-clocks without input hysteresis** (direct breadboard wires, no series resistor). Two of three full-design placements counted **39.89–40.74 MHz**, wandering in both directions, where the C5 sends 40.000236 MHz; the older placement counted exactly. The lclk DSP chain was corrupted with it: 32–533 H syncs/s on a clean PAL signal (raw captures clean through the bit-exact model: 4.7 µs sync at −2.1 MHz). Same placement with only `HYSTERESIS=HIGH` on pin 77 (`&HYSTERESIS=HIGH` added to the routed netlist, repacked, 21 fuse characters differ): **40.000234–40.000236 MHz**, steady; repeated A/B without → with gave the same split. Then with the VTX on: video_timing locked, **15,250 H syncs/s** (15,625 minus the 375/s that the vertical interval replaces), **250 broad pulses/s**, tip −1.46 MHz, blanking −0.62 MHz, 50 fields/s. Now in `tangnano20k.cst`. The 33 Ω series resistor (FPGA_LINK §2.2) remains the intended termination. | Q | Tang Nano 20K + C5-Zero, `link_sniff.py` strobe count and captures, Tank II A1 25 mW | 2026-09-25 |
| M70 | **AVI InfoFrame active format "4:3 centred" (PB2 = 0xA9) at 720p50 makes the user's monitor lose and regain the picture every few seconds.** Each variable was isolated on hardware, with no video: full design at 720p60, 720p59.94 (after a PLL restart) and 720p60 with PAL processing forced are all steady; 720p50 flickers. At 720p50, switching only the menu Aspect item (which only changed PB2) gave 16:9 (0xA8) steady and 4:3 (0xA9) flickering, and switching back reproduced both. The colour-bar bitstream (0xA8) is steady at 60/50/DVI, so M57 holds. The InfoFrame is valid CEA-861, so this is a monitor quirk. Fix: always send R = 1000 (same as picture); the 4:3 pillarbox is drawn into the frame. | Q | Tang Nano 20K, user's HDMI monitor, FPGA_DEBUG log | 2026-09-25 |
| M71 | **The frame-buffer writer wedged on real video.** With the VTX on and video_timing locked (~15,200 H syncs/s), `fields` counted for a few seconds and then froze, and the FIFO overflow counter saturated. The new diagnostics register froze at fb_ctrl state `[have_newest w_started w_line]`: inside a line, nothing in flight. Cause: a real line can arrive short (the resampler restarts it early, or the FIFO drops words while full). When its length is a multiple of 8, the next descriptor reaches the FIFO head on a burst boundary; the writer only writes non-descriptor words inside a line and only handles descriptors outside one, so it waits forever. Reproduced in `sim/tb_fb.v -GSHORT=296`: the old fb_ctrl hangs, 300 words only glitches. Fix: close the line when a descriptor is at the head. After the fix on hardware, fields count continuously at 50/s with `late=0` for the whole locked period. PLL LOCK drop counters stayed 0 throughout. | Q | Tang Nano 20K + C5-Zero, Tank II A1, diagnostics register 0x3000_0048 | 2026-09-25 |
| M72 | **nextpnr cannot reliably legalise MULT9X9 cells when the DSP blocks are ~90 % full** (32 MULT18X18 + 22 MULT9X9 = 43 of 48 sites; all DSP control pins constant, so no control-set conflict). With the default attempt limit (cells² / 8 ≈ 1e8) the HeAP legaliser spun for hours. With `--placer-heap-cell-placement-timeout 20000` each seed fails within seconds, naming the scaler MULT9X9 `u_out.hpb0…`: 4 of 5 seeds failed on one build, and 6 of 6 after one more register bit. `static` placement is unsupported for Gowin and `sa` segfaults. Fix: the techmap sends constants with up to 5 set bits to shift-and-add (was 2), which takes the output colour matrix (3–5 set bits, ~2 DSPs each) off the DSPs: 23 MULT18X18 + 20 MULT9X9 (~33 of 48 sites). | Q | nextpnr-himbaechel (OSS CAD Suite), GW2AR-18 | 2026-09-25 |
| M73 | **Decoder activity on a locked signal makes the HDMI output fail**; the display content, SDRAM traffic, VTX radio and ground wiring do not. Main design, menu Test pattern on (internal bars; the displayed picture ignores the receiver): VTX on + Decoder Idle (fm_frontend / video_timing / chroma_dec held in reset) -> monitor steady; VTX on + Decoder Run -> monitor power save; VTX off + Run -> picture back, with more sparkle noise. Also steady with the VTX on: the colour-bar bitstream, the colour-bar bitstream clocked by the cascaded clk_gen, and the main design with the C5 unplugged (lclk stopped). Not the cause: 1 -> 3 ground wires between the boards (link edge errors dropped from ~1000-20000 to 1-46 ppm, as FPGA_LINK §2.2 intends) and the C5 on a phone charger. With the Tang Nano on a phone charger (bitstream in flash) the monitor kept a signal but showed black. In every failing run, FPGA-side status was nominal: strobe exact, no PLL LOCK drops, fields flowing. Interpretation (unproven): the main design's HDMI signal is marginal (dashes and ragged edges in the internal bars look like TMDS bit errors, not frame-buffer corruption, which is 0 errors in simulation), and decoder switching activity pushes it over the edge. | Q | Tang Nano 20K + C5-Zero, Tank II A1 25 mW, user's HDMI monitor, FPGA_DEBUG logs | 2026-09-25 |
| M74 | **Logic clocked by the asynchronous C5 STROBE disturbs the HDMI output; the same logic on the pixel clock does not.** Instrument: HDMI capture card (Logitech Screen Share, MJPEG 1080p30), valid JPEG frames in 5 s (clean ≈ 55). Colour-bar bitstream: 55. + 1× fm_frontend on STROBE (real link pins): 53. + 4× fm_frontend on STROBE: **0**, with real link data and with internal LFSR data (no link pins). + 4× fm_frontend on pclk (LFSR at pclk/2): **54**. Main design, host-driven menu: Decoder Idle 55, FM only (fm_frontend running, video_timing / chroma_dec in reset) **0**, `rate_changes` 0. So it is neither a logic bug nor the link pins, and not routing distance to the OSER10s (checked); the main design's higher baseline activity crosses the threshold with 1×. The card locks up (USB error -71) after receiving the broken signal. Necessary but not sufficient (the monitor still went to power save with the VTX on; the rest was pixel-domain timing, M75): capture on STROBE, cross to pclk through a 16-entry FIFO, and run the whole receive chain on pclk with a sample-valid enable. The chain is clock-rate independent after video_timing's gain divider advances per sample: sim/tb_chain_a GAP=1 and sim/tb_full GAP=1 (a 1280×720 PAL frame) are bit-identical to the 40 MHz runs. | Q | Tang Nano 20K, capture card, FPGA_DEBUG log | 2026-09-25 |
| M75 | **nextpnr's timing report hid real pixel-clock violations; Gowin's own analysis found them.** The same RTL built with Gowin EDA 1.9.11.03 (Education, headless: `make gowin`, `fpga/gowin/`) reported **608 failing setup paths** at 74.25 MHz, which nextpnr-himbaechel had passed: TMDS encoder, OSD window position, out_path line-cache key and index adders, video_timing (H-PLL adder chain, gain/level multiply, resampler bookkeeping), chroma_dec (burst, mixer and saturation multipliers), fb_format and the fm_frontend half-band / LUT output. Each was pipelined without changing the sample stream (bit-exact against the host models and against saved reference copies of the old modules, with negative controls). Result: **0 failing setup and 0 hold paths**, pclk Fmax 78.7 MHz (+6 %; 80.1 MHz after M76's change), clk27 85 MHz, lclk 109–125 MHz. The pipelined video_timing needs ≥ ~2.5 clocks per 20 MS/s sample, so the testbenches now default to the gapped 74.25 MHz clock. Hardware: with the timing-clean bitstream, decoder running and VTX off, the capture card receives a clean OSD picture (55 frames in 5 s, the open-flow build: 0), and with the VTX on the first camera picture comes through (M76). `tools/gowin_timing.py` fails the build on any violation. | Q | Tang Nano 20K, Gowin EDA timing report `impl/pnr`, capture card | 2026-09-25 |
| M76 | **First camera picture; the Tank II needs far less de-emphasis than the NTSC 13.4 dB curve** (closes P6 for this VTX). Rush Tank II, 25 mW A1, ~2 m: PAL locked at 720p50, 10 s steady (vlock 1, no restarts, late 0, 0 FIFO overflows, ~15,250 H syncs/s = 15,625 minus vertical-interval pulses). Picture faults with the old de-emphasis: right-hand smear, low saturation (\|C\| ≈ 14 codes on the capture), horizontal bands where **U changes sign and V does not** (floor: Cb −10 / Cr +10 → Cb +13 / Cr +4). Raw C5 ring (3 × 26,624 samples at 40 MS/s, `bringup/c5_ring_dump.py`) through the bit-exact front end: 0 clicks, line spacing 1280 ± 1 samples, a normal PAL burst (±45° swing, ±10° jitter, frequency at nominal fsc within ~100 Hz), I/Q radius 3.4 nibble LSB. **Before de-emphasis, burst / sync depth = 0.619** (nominal 0.5, so the link is ~+1.9 dB at 4.43 MHz: little or no pre-emphasis), and the averaged sync edges show **no pre-emphasis overshoot**. The 0.8162 µs / 13.4 dB de-emphasis cuts 4.43 MHz by 13.2 dB and stretches the sync fall to ~2 µs. Raw noise: 656 kHz rms per 20 MS/s sample (4-bit phase quantisation, mostly high frequency). Simulation did not reproduce the bands: synthetic PAL with a +23 ppm VTX clock (sync edges drifting across the sample grid) decodes with hue sd 1.1°, and at the Tank II chroma level (0.38) only isolated 2-line glitches appear. Hardware A/B with the new run-time de-emphasis (menu, roof 13.4 / 8 / 4 dB / off, same pole; capture-card frames): **13.4 dB** smeared, washed out, purple bands; **8 dB** sharper, bands still on the shelf edge; **4 dB** sharp, correct colours (brown shelf, red box), no bands; **off** sharpest and most saturated, visibly noisier. Default is now **4 dB** (saved setting, blob version 2). Why the bands follow the de-emphasis is not established. Capture-card note: at a 50 Hz input it delivers ~20 fps with dropped / truncated JPEGs and may stall after a few seconds; after stream start the first ~2–3 s are empty, so grabs shorter than ~4 s read as "no signal". | Q | Tang Nano 20K + C5-Zero, Tank II A1 25 mW, capture card, C5 ring dumps, `model/iqsynth.py --ppm/--chroma` | 2026-09-25 |

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
| P6 | Tank II pre-emphasis fit (luma step / multiburst capture) | THEORY §6.4; de-emphasis constants. **Partly done (M76):** raw burst/sync and edge shape show little or no pre-emphasis; a proper curve fit (luma step or multiburst from the camera) is still open | Phase 1 |
| P7 | Channels > 5885 MHz (E6–E8, R8) and L band tuning | THEORY §3 reachability | Phase 1 |
| P8 | Board current/temperature of the C5-Zero | "gets warm"; expected, not measured | Phase 2 |
| P9 | FPGA-link electrical items L3.1–L3.6 (strobe, skew, termination, UART, scan) | docs/FPGA_LINK.md §5 | Phase 3 |
| P10 | GOLDEN clamped vs fold-back LUT A/B, and XIAO boot on IDF 6.1 | needs the DAC board | Phase 1/2 |
| P11 | Tang Nano 20K: header bank voltage (schematic); LED1 (SDRAM ready) on `make prog-top` | pinlabel figure only (monitor lock done: M57) | Phase 4 |
| P12 | Monitor's own reported refresh rate at 59.94 / 50 (optional cross-check) | switching works and the rate is stable (M64); the TMDS frequency is measured (M59) | Phase 4 |
| P13 | Link eye at the FPGA: IOB capture on the rising STROBE edge vs falling edge; bit-error check with the C5's own capture | FPGA_LINK §2.3; no PLL left for a ×4 phase scan | Phase 4 |
| P14 | Latency RF sample → TMDS pixel (e.g. LED flash on camera → photodiode on monitor, or a scope on the VTX video and HDMI) | plan Phase 4 requirement; estimate only (≈ 1 field + 0–1 output frame) | Phase 4 |

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
