# Phase 4 — FPGA project (Tang Nano 20K)

Status: **feature-complete in simulation; hardware lab tests pending.** The gate report and the
post-gate decisions and results are in fpga/README.md §5.

## Done up to the gate

- Toolchain: OSS CAD Suite 2026-09-23 (yosys 0.69+136, nextpnr-himbaechel, apicula,
  openFPGALoader). Gowin EDA was not needed.
- Bring-up bitstream `make pattern`: 720p50/60 colour bars with InfoFrame and a DVI fallback.
  Loaded to SRAM (JTAG idcode 0x81b); the monitor shows it at 720p60, 720p50 and in DVI mode (M57).
- Receiver `make top`: link capture → fm_frontend → video_timing → chroma_dec → fb_format →
  async FIFO → fb_ctrl + sdram_ctrl (54 MHz) → line cache → out_path (bob, 4:3 pillarbox, dim on
  loss) → hdmi_tx/phy. Scaling is nearest-neighbour; the plan allows that only as a debug mode,
  and the polyphase scaler is the next step after the gate.
- Verification (`fpga/sim`, `make sim`, ~10 min):
  - FM front end: bit-exact (NTSC, and weak PAL with 9,571 clicks).
  - Chroma: bit-exact (NTSC comb and notch, PAL).
  - SDRAM controller: tested against a protocol-checking model.
  - Frame buffer: tested at real rates in both mismatch directions.
- Pins: `fpga/tangnano20k.cst` covers the clock, buttons, LEDs, HDMI and embedded SDRAM (apicula
  doc/sdram.md), plus the C5 link (Sipeed pinlabel figure). The wiring table is in
  fpga/README.md §2.

## Bugs found by simulation and fixed

- `out_path` vertical mapping was one output line ahead and had no rounding term. In PAL it
  fetched source line 288, which is the next buffer's line 0, the field being written.
  `tb_fb` caught it (tearing and wrong-line checks). Fixed with a start at vn = 0, a +360
  rounding term and a clamp to L−1.
- The output frame event moved from line 0 to line 740, in vertical blanking. The newest-field
  latch and the cur_odd/cur_pal crossing then settle before line 749 prefetches source line 0.
- `chroma_dec` shared one loop variable across three always blocks. The simulator was fine, but
  yosys saw multiple drivers. It was renamed, and the design is still bit-exact.
- yosys 0.69 left `$buf` cells, which nextpnr cannot place, for registers with trimmed low bits.
  They are removed by a post-synthesis `setundef`/`techmap`/`opt_clean` in the Makefile.
- A 0.12 ns hold violation into the phase-LUT BSRAM address pins was fixed by capturing the link
  in the IOB (`--vopt ireg_in_iob`) and feeding the LUT from there.

## Gate result

It fits (34 % LUT, 30 % BSRAM, 60 % MULT18) and closes (pclk Fmax 87.4 MHz against 74.25 MHz). Three
items need a decision before the scaler (README §5.4):

- (a) Exact 720p59.94 needs both rPLLs cascaded, which pushes the SDRAM onto pclk. Otherwise
  NTSC output stays at 60.00.
- (b) The link eye scan needs a PLL that no longer exists; use the IOB rising-edge capture plus
  lab item P13.
- (c) The 4+4-tap scaler DSP budget fits with ~3.5 of 48 slots spare, with fallbacks listed.

## After the gate (2026-09-24)

User decisions: option 1 (exact 59.94 Hz via cascaded PLLs; SDRAM on the pixel clock), IOB capture
on the rising STROBE edge, and 4-tap filtering in both directions.

- **Clocking** (`rtl/clocks/clk_gen.v`). Two cascaded rPLLs with dynamic dividers, retuned from the
  crystal domain. The encoding and the frequencies were measured on the board first, with
  `bringup/pll_probe.v` and `pll_cascade_probe.v` (M58, M59).
- **SDRAM on the 74.25 MHz pixel clock.** CL 2 with read latency 4, chosen from a hardware sweep
  plus a 60 s soak (M60). `sdram_ctrl` now takes CL as a parameter and read latency / capture
  edge as runtime inputs.
- **Frame buffer.** Five buffers, so weave can hold two fields while the writer publishes twice per
  output frame. Single clock with the output path.
- **Output path.** Bob/weave into a 4-tap Catmull-Rom polyphase vertical and horizontal scaler (Y and
  chroma separately), with a 5-slot line cache and interleaved line banks. Bit-exact against
  `model/scaler_ref.py`.
- **OSD.** 40×16 cells with the Spleen 8×16 font (BSD-2, vendored) at ×2. **Control CPU:**
  PicoRV32 (ISC, vendored) on the crystal clock, running `firmware/` (menu, buttons, C5 link
  over `src/link_proto.h`).
- **Verification** moved to Verilator for the long benches (30–70× faster): quick tier about 3 min,
  everything about 1.5 min. New benches: UART loopback, a control-CPU scenario, the scaler (5
  configurations) and RF → pixels for NTSC and PAL, bit-exact against the host models.
- **Bugs found and fixed:**
  - `fb_format` descriptor width (37 → 36 bits: almost every line was dropped);
  - `fb_format` line tags one line off;
  - partial field published after an SDRAM restart;
  - UART stop bit one clock long on back-to-back bytes;
  - firmware waited 0.5 s before its first GET_SETTINGS;
  - a pclk timing failure in the cache-fetch logic, fixed by pipelining it (41.7 → 88 MHz).

Open lab items: P11–P14 (docs/MEASUREMENTS.md), plus the first end-to-end run with the C5-Zero
wired to the FPGA.
