# Phase 4 — FPGA project (Tang Nano 20K)

Status: **stopped at the plan's resource/timing gate.** The full report is in
[fpga/README.md §5](../../fpga/README.md#5-phase-4-gate-report).

## Done up to the gate

- Toolchain: OSS CAD Suite 2026-09-23 (yosys 0.69+136, nextpnr-himbaechel, apicula,
  openFPGALoader). Gowin EDA was not needed.
- Bring-up bitstream `make pattern`: 720p50/60 colour bars with InfoFrame and a DVI fallback.
  It is loaded to SRAM (JTAG idcode 0x81b), but no monitor result has been reported yet (lab P11).
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
