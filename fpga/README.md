# C5VRX FPGA — Sipeed Tang Nano 20K

The Tang Nano 20K (Gowin GW2AR-LV18QN88C8/I7) does everything after the tuner. It demodulates the
C5-Zero's 4-bit I/Q, decodes NTSC/PAL colour, stores fields in the embedded SDRAM and scans them out as
free-running 720p HDMI. The C5 side is described in [docs/FPGA_LINK.md](../docs/FPGA_LINK.md). The
signal theory is in [docs/THEORY.md](../docs/THEORY.md).

Status: **Phase 4 gate.** The decode chain, frame buffer and 720p output are complete and simulated.
The polyphase scaler, OSD/menu and UART control link come after the gate (see §5).

## 1. Toolchain and build

The flow is entirely open source: yosys `synth_gowin` → nextpnr-himbaechel → apicula `gowin_pack`,
then openFPGALoader. It was tested with OSS CAD Suite 2026-09-23 (yosys 0.69+136), installed at
`~/.local/opt/oss-cad-suite`. Override the location with `make OSS=...`.

```sh
make top           # full receiver bitstream -> build/top.fs (plus top-stat.txt, top-pnr.log, top-report.json)
make prog-top      # load into SRAM (volatile; power-cycle returns to the flashed design)
make pattern       # 720p colour-bar bring-up bitstream (S1: 50/60 Hz, S2: HDMI/DVI)
make prog-pattern
make sim           # regressions (sim/Makefile): generates vectors, runs RTL, compares with the models
```

To write the design to flash, use `openFPGALoader -b tangnano20k -f build/top.fs`. That is not needed
for testing.

Python host models (`model/`, numpy):

| file | purpose |
|---|---|
| `iqsynth.py` | synthetic composite (bars) → pre-emphasis → FM → 4-bit I/Q bytes, with noise and carrier offset |
| `ref.py` | FM front end reference (bit-exact); writes `rtl/dsp/phase_lut.hex` |
| `chroma_ref.py` | streaming chroma decoder reference (bit-exact); writes `sin_lut.hex` / `cos_lut.hex` |

## 2. Wiring (C5-Zero → Tang Nano 20K)

Tang Nano 20K pin numbers come from Sipeed's Tang Nano 20K pinlabel figure (wiki.sipeed.com,
Tang Nano 20K). All header banks are 3.3 V LVCMOS, like the C5. The C5 GPIOs come from
`src/boards/waveshare_c5zero_fpga.h`. Wiring rules (33 Ω series resistors at the C5, ≤ 10 cm, GND every
2–3 wires) are in docs/FPGA_LINK.md §2.2.

| Signal | C5-Zero GPIO | Tang Nano 20K pin | Header | FPGA port |
|---|---:|---:|---|---|
| I/Q bit 0 (Q LSB) | 0 | 42 | right | `link_d[0]` |
| I/Q bit 1 | 1 | 41 | right | `link_d[1]` |
| I/Q bit 2 | 4 | 56 | right | `link_d[2]` |
| I/Q bit 3 (Q MSB) | 5 | 54 | right | `link_d[3]` |
| I/Q bit 4 (I LSB) | 6 | 51 | right | `link_d[4]` |
| I/Q bit 5 | 7 | 48 | right | `link_d[5]` |
| I/Q bit 6 | 8 | 55 | right | `link_d[6]` |
| I/Q bit 7 (I MSB) | 9 | 49 | right | `link_d[7]` |
| STROBE 40 MHz | 10 | 77 (GCLKT_1) | left | `link_strobe` |
| UART C5 → FPGA | 11 | 72 | right | `link_rx` |
| UART FPGA → C5 | 12 | 71 | right | `link_tx` |
| GND | GND | GND (≥ 3 wires) | both | — |

`link_d[k]` is PARLIO RX data bit k, so the byte is `{I[3:0], Q[3:0]}`, exactly what the C5 captures.
STROBE is on a true global-clock input (GCLKT_1). On the board, pin 77 is also routed to the RGB-LCD
FPC as LCD_CLK, so leave the LCD connector empty. The data pins avoid the LEDs (15–20), buttons (87/88),
HDMI (33–40), EDID (52/53) and the SD-card pins. Power the C5-Zero from the Tang Nano's 5 V pin so
both boards share one ground.

On-board: S1 = pin 88 and S2 = pin 87 (menu, post-gate). LEDs 0–5 (active low) show:
LED0 = both PLLs locked, LED1 = SDRAM ready, LED2 = video_timing locked, LED3 = PAL detected,
LED4 = a complete field is in the frame buffer, LED5 = STROBE heartbeat (~2.4 Hz).

## 3. Architecture

```
             lclk = STROBE 40 MHz (from the C5)                    sclk 54 MHz          pclk 74.25 MHz (fclk/5)
 link_d ─► IOB reg ─► fm_frontend ─► video_timing ─► chroma_dec ─► fb_format ─► async_fifo ─► fb_ctrl ◄─► sdram_ctrl ◄─► SDRAM 32-bit
          (40 MS/s)   k=1 disc.      sync/levels     burst NCO,    720 px       36 bit x 512    triple        8-word bursts
                      click repair   H-PLL, 1280-pt  comb/notch,   4:2:2 8 bit                  buffer        auto-precharge
                      halfband→20    line-locked     PAL-D, killer              line cache (4 slots, dual clock) ─► out_path ─► hdmi_tx ─► OSER10 x4
                      de-emphasis    resampler                                                              bob, 4:3/16:9, YCbCr→RGB   (fclk 371.25)
```

- **Sample rate (plan requirement "≥ 4× fsc").** The discriminator runs at 40 MS/s, and composite is
  resampled to a line-locked 1280 samples per line (20.1 / 20.0 MS/s = 5.6× NTSC fsc and 4.5× PAL fsc).
  The derivation is in THEORY §5–§7.
- **Frame buffer.** Three field buffers of 288 lines × 512-word pitch hold 720 px of 4:2:2 each
  (360 words per line, `{Cr, Y1, Cb, Y0}`). A field is published when the next field starts. The output
  side latches the newest complete field at output line 740 (vertical blanking), so a field is never
  read while being written.
- **Output.** 720p60 (VIC 4) or 720p50 (VIC 19). The rate follows the stored standard after 16
  agreeing frames. 4:3 content goes in a 960×720 window with 160 px black bars. Bob deinterlacing uses
  the half-line offset per field: source line k = ⌊((2y+1)L + 360 − 720p) / 1440⌋, with p = 0 for the
  odd/top field. The AVI InfoFrame is sent. Signal loss (no new field for 8 frames) dims the last
  frame, and the output never stops.

## 4. Verification (`make sim`)

| test | what | result |
|---|---|---|
| `fe` | fm_frontend vs `ref.py`: strong NTSC bars, and weak PAL (radius 110, noise 45: 9,571 clicks) | 41,997/41,997 bit-exact (both) |
| `chroma` | sync/levels/resampler on one field, then chroma_dec vs `chroma_ref.py`: NTSC comb, NTSC notch, PAL (PAL-D) | 255,998/255,998 bit-exact (each); hue within 0.3–1° on bars |
| `sdram` | sdram_ctrl vs a behavioural SDRAM with protocol checks (tRCD/tRP/tRC/CL, tAC 5.4 ns, tOH 2.5 ns) | 512 words, 0 mismatches, 0 protocol errors |
| `fb` | FIFO → fb_ctrl → SDRAM model → line cache → out_path at real rates: NTSC 59.94 in / 720p50 out, and PAL 50 in / 720p60 out. Checks word/line/slot tags, no tearing, never the field being written, fields never go backwards, bob mapping on all 720 lines | both PASS: 1 drop / 1 repeat in 7 frames, as expected; 0 errors |

Still to come (post-gate): the full-chain PNG frame dumps with SMPTE/EBU bars, compared against the
Python reference.

## 5. Phase 4 gate report

The build is `make top` at the gate commit, with the pre-scaler design and nearest-neighbour vertical
and horizontal scaling. Figures are from nextpnr-himbaechel's post-route report.

### 5.1 Resources (GW2AR-18)

| resource | used | available | % |
|---|---:|---:|---:|
| LUT4 | 7,198 | 20,736 | 34 % |
| ALU (carry) | 3,986 | 15,552 | 25 % |
| DFF | 3,247 | 15,552 | 20 % |
| BSRAM (18 Kbit) | 14 | 46 | 30 % |
| MULT18X18 | 29 | 48 | 60 % |
| MULT9X9 | 7 | 96 | 7 % |
| rPLL | 2 | 2 | **100 %** |
| CLKDIV | 1 | 8 | 12 % |
| IOB | 51 | 384 | 13 % |

The multipliers are used by chroma_dec (8), video_timing (6), fm_frontend (5 + 2×9), fb_format (5) and
out_path (4 + 3×9), plus 1 + 2×9 in top-level glue. BSRAM holds the chroma line delays and sin/cos
tables (8), the out_path line cache (4), the FIFO (1) and the phase LUT (1).

### 5.2 Timing closure (`tangnano20k.sdc`)

| clock | target | post-route Fmax | margin |
|---|---:|---:|---:|
| pclk (pixel) | 74.25 MHz | 87.35 MHz | +17.6 % |
| sclk (SDRAM, fb_ctrl) | 54 MHz | 219 MHz | ×4 |
| lclk (link STROBE) | 40 MHz | 97.9 MHz | ×2.4 |
| fclk (TMDS) | 371.25 MHz | — | only drives the OSER10 FCLK pins (hard serialiser) |

There are no hold violations. The link capture registers sit in the input pads (`--vopt ireg_in_iob`).
An earlier build with the capture flop in the fabric had 0.12 ns hold violations at the phase-LUT
BSRAM address pins.

### 5.3 SDRAM bandwidth (54 MHz, 8-word bursts ≈ 16–18 clk each including ACT/auto-precharge)

| stream | bursts/s | clk/s |
|---|---:|---:|
| write: 45 bursts × 240 lines × 59.94 (PAL 288 × 50: same) | 648 k | 11.7 M |
| read, nearest/bob: each source line once per output frame, worst PAL at forced 60 Hz (288 × 60) | 778 k | 14.0 M |
| refresh: 1 per 421 clk, 7 clk each | 128 k | 0.9 M |
| **total** | | **26.6 M of 54 M = 49 %** |

A 4-tap vertical scaler still reads each source line once per output frame, because the line cache
holds the window, so the budget above does not change. Weave (two fields per frame) raises the read
stream to 28 M, a total of about 75 %.

### 5.4 Items that need a decision

**(a) 720p59.94 needs both PLLs.** The GW2AR-18 has only two rPLLs. One is used for TMDS
(27 × 55/4 = 371.25 MHz) and one for the SDRAM (54 MHz). 59.94 Hz needs 371.25 × 1000/1001 =
370.879 MHz, and 1001 = 7·11·13. No single rPLL ratio (FBDIV, IDIV ≤ 64) reaches it: the best is
55/4, which is 1000 ppm off, i.e. 60.00 Hz. The exact value needs two cascaded rPLLs:
27 × 50/7 = 192.857, then × 25/13 = 370.879 MHz (VCOs 771 and 742 MHz, PFDs 3.86 and 14.8 MHz).
Switching between 50/60 and 59.94 also needs both PLLs retuned (27 × 11/2 × 5/2 = 371.25), because
no fixed first stage serves both. Checked with this toolchain: nextpnr places the cascade, and
gowin_pack accepts `DYN_IDIV_SEL`/`DYN_FBDIV_SEL` on both PLLs. The bit encoding of the dynamic
IDSEL/FBDSEL ports and the relock behaviour on hardware are **UNVERIFIED**. Options:

1. **Recommended.** Cascade both PLLs for TMDS and retune them dynamically on a standard change.
   Run the SDRAM and fb_ctrl from pclk (74.25/74.18 MHz) instead of their own PLL. That also removes
   the sclk↔pclk crossing. Cost: the SDRAM runs at 74 MHz, so CL 2 → 3 (RD_LAT +1) and ~40 % higher
   bandwidth. The frame buffer is re-initialised on a standard change, which is a mode switch anyway.
   Needs a hardware test of the dynamic divider encoding. The monitor's info OSD should show 59.94 Hz.
2. Keep 60.00 Hz for NTSC. Simplest, and the build is already done. The cost is one repeated field
   about every 16.7 s, which contradicts the plan's "no judder" for NTSC.
3. Gowin EDA would not help: this is a silicon PLL limit, not a tool limit.

**(b) Link sampling phase.** docs/FPGA_LINK.md §2.3 recommended locking a PLL to STROBE at ×4 and
scanning the eye. No PLL is left for that (see a). The gate build instead samples in the IOB on the
rising STROBE edge, the same edge the C5 samples on, so the FPGA sees the C5's own byte stream
apart from pad-to-pin skew. If the lab (L3.1/L3.3) shows a marginal eye, the fallback is an IODELAY
step per pin, or IDDR capture on both edges. Neither needs a PLL.

**(c) DSP budget for the scaler.** A 4-tap vertical plus 4-tap horizontal polyphase on
Y/Cb/Cr needs 24 × MULT9X9 (8-bit samples × 9-bit coefficients). Assuming two 9×9 per 18×18 slot,
the used equivalent grows from 32.5 to 44.5 of 48, which fits with 3.5 slots spare. If it gets
tight: fb_format's 5 multipliers run at ≤ 20 MS/s and can be time-shared or moved to LUTs, and the
horizontal pass (720 → 960 or 1280) can be 2-tap bilinear, which is allowed by the plan as a minimum.
Projected LUT total with scaler, OSD (font ROM + text RAM = 2 BSRAM, 8 cache slots = +4 BSRAM),
UART and menu: ~50 % LUT and ~20 of 46 BSRAM.

Lab items still open for this phase (MEASUREMENTS.md P-list): monitor lock on 720p50/60 from
`make prog-pattern`, SDRAM on real silicon, link eye (L3.x), and latency RF → TMDS.
