# C5VRX FPGA — Sipeed Tang Nano 20K

The Tang Nano 20K (Gowin GW2AR-LV18QN88C8/I7) does everything after the tuner. It demodulates the
C5-Zero's 4-bit I/Q, decodes NTSC/PAL colour, stores fields in the embedded SDRAM and scans them out as
free-running 720p HDMI. The C5 side is described in [docs/FPGA_LINK.md](../docs/FPGA_LINK.md). The
signal theory is in [docs/THEORY.md](../docs/THEORY.md).

Status: **Phase 4 feature-complete, awaiting lab tests.** Complete and simulated: decode chain,
5-buffer field store, bob/weave deinterlacing, 4-tap polyphase scaler, OSD menu, control CPU and
C5 UART link. The clocking and SDRAM timing are measured on the board (§5.5). The C5 link has not
been wired yet.

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
make -C firmware   # control CPU firmware -> firmware/build/fw.hex (make top does this too)
```

The firmware is built with the RISC-V GCC that PlatformIO installs for the ESP32-C5
(`~/.platformio/packages/toolchain-riscv32-esp`, rv32i/ilp32 multilib; override with
`make -C firmware CROSS=...`).

**Release builds use Gowin EDA** (`make gowin`, MEASUREMENTS M75). nextpnr's timing model is
optimistic on this device: it passed a design that Gowin's analysis showed failing 608 paths at
74.25 MHz, and that design broke the HDMI output on real hardware. The open flow stays useful
for quick iteration, but check timing with Gowin before trusting a bitstream on the board.
Gowin EDA 1.9.11 Education (free) is enough; unpack it to `~/.local/opt/gowin` (or set `GOWIN=`).
`tools/gowin.sh` runs its shell headless, `gowin/top.tcl` is the project (same sources as
`make top`), `gowin/make_cst.py` converts the pin constraints to Gowin syntax, and
`tools/gowin_timing.py` fails the build on any setup or hold violation.

```sh
make gowin         # vendor build -> impl/pnr/top.fs (~2 min), then the timing check
make prog-gowin    # load impl/pnr/top.fs into SRAM
```

Vendored third-party sources (`third_party/`, pinned commits):

| component | licence | source |
|---|---|---|
| PicoRV32 RV32I core | ISC | github.com/YosysHQ/picorv32 @ ef203c2 |
| Spleen 8×16 font (OSD) | BSD-2-Clause | github.com/fcambus/spleen @ 57f9219 |

Bring-up probes (`bringup/`, each loads into SRAM and reports over the BL616 USB-UART at 115200 baud,
`/dev/ttyUSB1` on the host): `pll_probe.v` measures the rPLL dynamic divider encoding,
`pll_cascade_probe.v` measures the run-time retuning of the cascaded PLLs, and `sdram_probe.v`
sweeps the SDRAM CAS latency, read latency and capture edge at 74.25 MHz. `iob_probe.v` tests the
pad input registers (they read a constant 0: M61), and `lock_probe.v` counts PLL LOCK drops per
second.

**Debug tap.** Everything the FPGA sends to the C5 is mirrored on the BL616 USB-UART
(`dbg_tx`, pin 69, 1 Mbaud). The firmware adds a `LINK_MSG_FPGA_DEBUG` frame once per second
carrying the status word, the clock-generator restart counter and cause, and the output-rate
state. The C5 ignores it. Watch it with:

```sh
python3 bringup/link_sniff.py /dev/ttyUSB1 60     # decoded frames with timestamps, for 60 s
```

To write the design to flash, use `openFPGALoader -b tangnano20k -f build/top.fs`. That is not needed
for testing.

Python host models (`model/`, numpy):

| file | purpose |
|---|---|
| `iqsynth.py` | synthetic composite (bars) → pre-emphasis → FM → 4-bit I/Q bytes, with noise and carrier offset |
| `ref.py` | FM front end reference (bit-exact); writes `rtl/dsp/phase_lut.hex` |
| `chroma_ref.py` | streaming chroma decoder reference (bit-exact); writes `sin_lut.hex` / `cos_lut.hex` |
| `scaler_coef.py` | 4-tap Catmull-Rom polyphase table (32 phases, Q7); writes `rtl/out/cr_coef.vh` |
| `scaler_ref.py` | deinterlace + scaler + RGB reference of `out_path.v` (bit-exact), test fields |
| `chain_ref.py` | full-chain reference after video_timing: chroma → `fb_format` (bit-exact model inside) → scaler |
| `font_rom.py` | OSD font ROM from the Spleen BDF, plus bar-graph and cursor glyphs |

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

On-board: S1 = pin 88 and S2 = pin 87 (menu, §3.1). LEDs 0–5 (active low) show:
LED0 = HDMI PLLs locked, LED1 = SDRAM ready, LED2 = video_timing locked, LED3 = PAL detected,
LED4 = a complete field is in the frame buffer, LED5 = the C5 STROBE is running.

## 3. Architecture

```
 clk27 (crystal) ─ PicoRV32 + firmware: menu, buttons, OSD text, C5 UART link (1 Mbaud) ─┐ settings / status (cdc_bus)
                 ─ output-rate choice ─► clk_gen: 2 cascaded rPLLs, retuned at run time ─► fclk 371.25 / 370.879 MHz, pclk = fclk/5
 lclk = STROBE 40 MHz (from the C5)                                      pclk 74.25 / 74.176 MHz
 link_d ─► IOB ─► fm_frontend ─► video_timing ─► chroma_dec ─► fb_format ─► async ─► fb_ctrl ◄─► sdram_ctrl ◄─► SDRAM (32-bit)
                  k=1 disc.      sync/levels     burst NCO,     720 px 4:2:2 FIFO     5 field      CL 2, 8-word bursts
                  click repair   H-PLL, 1280-pt  comb/notch,                          buffers
                  halfband→20    line-locked     PAL-D, killer                           │ line fetches (5-slot cache)
                  de-emphasis    resampler                                               ▼
                                                  out_path: bob/weave → 4-tap vertical → 4-tap horizontal → RGB ─► osd ─► hdmi_tx ─► OSER10 x4
```

- **Sample rate (plan requirement "≥ 4× fsc").** The discriminator runs at 40 MS/s, and composite is
  resampled to a line-locked 1280 samples per line (20.1 / 20.0 MS/s = 5.6× NTSC fsc and 4.5× PAL fsc).
  The derivation is in THEORY §5–§7.
- **Frame buffer.** Five field buffers of 288 lines × 512-word pitch hold 720 px of 4:2:2 each
  (360 words per line, `{Cr, Y1, Cb, Y0}`). A field is published when the next field starts. At output
  line 740 (vertical blanking) the reader latches the newest complete field and the one before it,
  and the writer never uses either. Five buffers are the minimum: weave holds two fields, and at
  59.94 → 50 Hz the writer can publish twice between output frames.
- **Deinterlace.** Bob is the default and uses the per-field half-line offset. Source position:
  v = ((2y+1)L − 360 − 720p)/1440 field lines, with p = 0 for the odd/top field. Weave interleaves
  the newest two fields (v = ((2y+1)L − 360)/720 frame lines). It is used only when both fields are
  complete and of the same standard; otherwise the output falls back to bob.
- **Scaler.** 4-tap Catmull-Rom polyphase with 32 phases, vertically and horizontally, with Y and
  Cb/Cr filtered separately (chroma co-sited, 360 samples per line). Vertical: a 5-slot line cache
  always holds the 5 consecutive source lines around the next output line. Each output line is
  filtered one pixel per clock into 4-way interleaved line banks, one line ahead. Horizontal: one
  output pixel per clock reads 4 adjacent samples from the 4 banks. 4:3 content goes in a 960×720
  window with 160 px black bars, or is stretched to 1280×720 for 16:9.
- **Output rate.** 720p50 (VIC 19) for PAL, 720p59.94 (VIC 4, pixel clock 74.25×1000/1001) for NTSC,
  or Force 60. The rate follows the effective standard once it has held for 0.5 s with video
  locked, or immediately when the standard is forced in the menu. A switch retunes the PLL cascade
  (~0.3 ms) and restarts the pixel domain, SDRAM included. The monitor re-syncs once. The CPU runs
  on the crystal and keeps its state.
- **Signal loss.** When no new field arrives for 8 output frames, the output shows either the last
  frame dimmed or a dark-blue "no signal" screen (menu choice), plus an OSD banner. HDMI timing
  never stops.
- **OSD.** 40×16 character cells (Spleen 8×16 font, scaled ×2), overlaid after scaling. The cells
  are drawn by the CPU through a back buffer, so updates are flicker-free.

### 3.0 First power-up with the C5 wired

1. Flash the C5-Zero: `pio run -e waveshare_c5zero_fpga -t upload`.
2. Load the FPGA: `make -C fpga prog-gowin` (or `openFPGALoader -b tangnano20k -f fpga/impl/pnr/top.fs`
   to write it to flash).
3. The C5 sends the wiring pattern at every boot. If the FPGA was loaded later, it asks the C5
   to reboot once and resend it. A wiring fault opens **Link status** on the OSD with the faulty
   line(s); a pass is silent. Menu → Link status shows the result, both UART directions, the
   strobe frequency (expect 40.000 MHz) and per-bit activity.
4. `python3 fpga/bringup/link_sniff.py /dev/ttyUSB1 60` shows the same data from the host once
   per second.

### 3.1 Buttons and menu

S1 and S2 on the Tang Nano 20K. The C5-Zero BOOT button arrives over the link and acts as S1.
A long press is ≥ 0.7 s and fires while the button is still held.

| state | S1 short | S1 long | S2 short | S2 long |
|---|---|---|---|---|
| menu hidden | open menu | open menu | next channel (banner) | previous channel |
| menu | next item | select / edit | previous item | close menu |
| editing a value | next value | done | previous value | done |
| scan results | tune the best channel | back | — | back |

Menu items: Channel (band/channel and MHz), Scan (the C5 sweeps all 48 channels; per-channel
quality bars), Standard (Auto/NTSC/PAL, also sent to the C5 as a hint), Output rate (Auto 50/59.94,
Force 60), Aspect (4:3, 16:9 stretch), Deinterlace (Bob/Weave), Brightness, Contrast, Saturation,
Hue (NTSC), Y/C filter (Comb/Notch), Signal loss (Last frame/No signal), Link status (wiring
test result, UART both ways, strobe frequency, bit activity, edge-placement errors; S1 re-runs
the wiring test), Save (the settings go to
the C5 as an opaque blob, `LINK_MSG_SET_FPGA_SETTINGS`, and are saved to NVS with
`LINK_MSG_SAVE_SETTINGS`), Exit. The menu hides after 15 s without input. The title row shows the
channel, frequency and an RSSI bar. The bar is the C5's 0..100 Q4 quality score, not calibrated dBm.
After boot the firmware asks the C5 for its settings (`GET_SETTINGS`, retried every 0.5 s) and
applies the saved blob.

## 4. Verification (`make sim`)

`make -C sim -j4 quick` runs every block once in about 3 minutes; `make -C sim -j4` runs all
configurations in about 1.5 minutes once the vectors exist. The long testbenches run under
Verilator (`--binary --timing`), 30–70× faster than Icarus: the control-CPU test takes 60 s
instead of about 90 min. `make lint` (Verilator, seconds) catches wiring errors before a
place-and-route.

| test | what | result |
|---|---|---|
| `fe` | fm_frontend vs `ref.py`: strong NTSC bars, and weak PAL (radius 110, noise 45: 9,571 clicks) | 41,997/41,997 bit-exact (both) |
| `chroma` | sync/levels/resampler on one field, then chroma_dec vs `chroma_ref.py`: NTSC comb, NTSC notch, PAL (PAL-D) | 255,998/255,998 bit-exact (each) |
| `sdram` | sdram_ctrl vs a protocol-checking SDRAM model at 74.25 MHz, CL 2 | 0 mismatches, 0 protocol errors |
| `uart` | UART loopback, 300 back-to-back bytes at 1 Mbaud | 300/300 |
| `fb` | FIFO → fb_ctrl → SDRAM → line cache at real rates: NTSC 59.94 → 720p50 and PAL 50 → 720p60, bob and weave. Checks word/line tags, no tearing, never the field being written, fields never go backwards, weave pairs consecutive fields, the 4 vertical tap lines of every output line, no late fetch | 4/4 PASS (1 drop / 1 repeat in 7 frames, as expected) |
| `scaler` | fields → fb_ctrl → SDRAM → out_path, whole 1280×720 frame vs `scaler_ref.py`: PAL/NTSC, bob/weave, 4:3/16:9, odd and even fields | 5/5 bit-exact (921,600/921,600 pixels each) |
| `soc`, `soc-faults` | PicoRV32 + firmware vs a scripted C5 (SETTINGS, 10 Hz STATUS, scan results), scripted S1 presses and the C5 wiring pattern embedded in random DIAG data: GET_SETTINGS at boot, menu, long-press scan, tune best channel, frame CRCs, wiring verdict with correct wiring and with D2↔D5 swapped, D3 open and STROBE open | 8/8 checks in each of the 4 runs |
| `clkgen` | clk_gen against a chattering-LOCK PLL model: one start, one restart per rate change, none from chatter | PASS |
| `linkmon` | link monitor: 4,000 samples per window, bit activity, 0 edge errors mid-eye vs ~16 % on the transitions | PASS |
| `full` | **RF → pixels:** 75 % bars → pre-emphasis → FM → 4-bit I/Q (`iqsynth.py`) → whole receive chain → 720p frame, vs the host models chained after video_timing (`chain_ref.py`), NTSC and PAL | bit-exact (921,600/921,600 each); bars within 1–15 codes of nominal RGB (saturated colours a few % high) |

PNGs of the scaler and full-chain frames (`*_rtl.png` / `*_ref.png`) land in `sim/data/`.

Bugs found by these tests and fixed: the `fb_format` descriptor was 37 bits wide, which dropped the
descriptor flag and discarded almost every line. The `fb_format` line tags were one line off.
`fb_ctrl` published the partial field seen right after an SDRAM (re)start. The UART
transmitter's stop bit was one clock long for back-to-back bytes. The firmware waited 0.5 s
before its first GET_SETTINGS. Before the gate: a one-line bob offset.

## 5. Phase 4 gate report (history)

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

There are no hold violations. (Gate build: the link capture registers sat in the input pads via `--vopt ireg_in_iob`; that feature was later found to read a constant 0 on this chip (M61). The final design captures in fabric flip-flops, with LUT delay buffers for hold.)
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

**(b) Link sampling phase.** *(Update: the pad-register capture described here does not work, M61;
capture is in fabric flip-flops.)* docs/FPGA_LINK.md §2.3 recommended locking a PLL to STROBE at ×4 and
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

### 5.5 Decisions and results after the gate

Decisions (user, 2026-09-24): (a) option 1, cascaded PLLs for exact 59.94 Hz, with the SDRAM on
the pixel clock; (b) IOB capture on the rising STROBE edge; (c) 4-tap filtering in both
directions.

Hardware measurements on this board (docs/MEASUREMENTS.md):

- M57: the bring-up pattern is displayed at 720p60, 720p50 and in DVI mode.
- M58: rPLL dynamic dividers: IDIV = 64 − IDSEL, FBDIV = 64 − FBDSEL (full sweep, 1,557 locked points).
- M59: cascade retuning 371.2499 ↔ 370.8790 MHz, within 0.3 ppm of target; relock about 0.3 ms.
- M60: SDRAM at 74.25 MHz: CL 2, first word 4 clocks after READ (the model predicts 3); a 60 s
  soak of 400.8 M words had 0 errors.

Final build (`make top`: the same flow, plus `--threads --router router2`):

| resource | used | available | % |
|---|---:|---:|---:|
| LUT4 | 12,522 | 20,736 | 60 % |
| ALU | 5,422 | 15,552 | 34 % |
| DFF | 5,845 | 15,552 | 37 % |
| BSRAM | 34 | 46 | 73 % |
| MULT18X18 | 30 | 48 | 62 % |
| MULT9X9 | 23 | 96 | 23 % |
| rPLL | 2 | 2 | 100 % |

| clock | target | post-route Fmax |
|---|---:|---:|
| pclk | 74.25 MHz | 88.1 MHz (other runs 87–90) |
| lclk | 40 MHz | 91.4 MHz (other runs 91–101) |
| clk27 (CPU) | 27 MHz | 130.8 MHz (other runs 119–134) |

(Fmax varies by a few MHz between place-and-route runs; every run so far has closed.)
