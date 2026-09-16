# C5VRX-3: Standalone Zero-EOF Production FPV Receiver

C5VRX-3 is an ultra-minimal, high-performance standalone 5.8 GHz analog video (FPV) receiver running on the **Seeed Studio XIAO ESP32-C5** (ESP32-C5 RISC-V SoC).

It captures raw Wi-Fi PHY I/Q samples directly from the RF front-end, demodulates Wideband FM (WBFM) in real-time hardware using the ESP32-C5 **BitScrambler**, and generates analog CVBS video output via **PARLIO TX** and a 6-bit resistor DAC ladder.

---

## Architecture

```text
RF @ 5865 MHz (ch 173) / BW40
  │
  ▼
Wi-Fi Modem ADC (40 MS/s I/Q, AGC frozen, fbw_sel=0, fixed gain 24)
  │
  ▼
MODEM_DIAG Bus (Q[9:6] & I[9:6] -> 8-bit Cartesian state)
  │
  ▼
PARLIO RX @ 40 MS/s (POS sample edge, pure continuous hardware GDMA)
  │
  ▼
Circular GDMA Ring (32 KiB in HP SRAM, Zero-EOF patched)
  │
  ▼
Phase5 BitScrambler Demodulator (fm.bsasm: 50 ns discriminator, 16-bit embedded LUT)
  │
  ▼
PARLIO TX @ 40 MHz ([D,D] mode -> 20 MS/s unique CVBS output)
  │
  ▼
6-bit Resistor DAC Ladder (GPIO 23, 24, 11, 12, 8, 9) -> Analog Video Monitor
```

---

## The Breakthrough: Zero-EOF Circular GDMA

### The Problem
During live hardware testing, the video signal suffered from two severe artifacts:
1. **Periodic vertical raster drops / black bars ("knalt om de seconde naar beneden")**: The monitor periodically lost vertical sync lock every 1–2 seconds.
2. **Horizontal edge distortion / jagged scanlines ("kartels")**: Video scanlines drifted horizontally, creating jagged diagonal and vertical lines.

Prior hypotheses suspected Wi-Fi timers, fractional video line buffer sizing (e.g. 30,000 vs 30,336 vs 45,760 bytes), or CPU bus stalls. However, line tuning only shifted the beat frequency and inverted the vertical jump direction.

### Root Cause in ESP-IDF Driver Source
Deep inspection of the ESP-IDF PARLIO driver revealed:
- In `components/esp_driver_parlio/src/parlio_tx.c` line 461:
  ```c
  .mark_eof = tx_unit->data_width == 1 ? !t->flags.loop_transmission : true;
  ```
  For 8-bit DAC output (`data_width == 8`), ESP-IDF **hardcodes `.mark_eof = true`**, setting `dw0.suc_eof = 1` on the final GDMA descriptor even when `loop_transmission = true`!
- In `components/esp_driver_parlio/src/parlio_rx.c` line 189:
  ```c
  mount_config[required_node_num - 1].flags.mark_eof = true;
  ```
  The RX driver also forces `suc_eof = 1` on the final descriptor of the circular ring.

Every time GDMA wrapped around the circular buffer, `suc_eof = 1` triggered a hardware EOF pulse into PARLIO TX and BitScrambler. This forced an internal hardware pipeline re-arm / FIFO stall (a microsecond "wrap bubble").
- When the bubble collided with V-sync, the monitor lost vertical sync and slipped a frame.
- When the bubble crossed active scanlines, it introduced horizontal line phase delays resulting in jagged edges ("kartels").

### The Solution: Zero-EOF Descriptor Patching
C5VRX-3 introduces `patch_descriptors_clear_eof()` in `main/video.c`. After starting PARLIO RX and TX:
1. It traverses the circular linked list of DMA descriptors (`dma_descriptor_t`) directly in HP SRAM.
2. It sets `dw0.suc_eof = 0` on **all** descriptors in both the RX and TX chains.
3. It performs cache writeback (`esp_cache_msync(..., DIR_C2M)`) and executes a memory fence (`fence rw, rw`).
4. It sets `PARL_IO.rx_genrl_cfg.rx_eof_gen_sel = 1` and disables GDMA RX interrupts (`AHB_DMA.in_intr.ena = 0`), eliminating ~9,775 CPU interrupts per second.

### The Result
- **Zero Wrap Bubble**: The hardware GDMA ring is now truly seamless and infinite.
- **Format Agnostic**: Buffer sizing is no longer tied to fractional video line math. Standard **32 KiB (`RAW_RING_BYTES 32768u`)** runs rock-solid.
- **Zero Jagged Edges ("kartels weg")**: 100% stable horizontal scanline lock.
- **Zero Vertical Sync Loss / Layer Jumps**: Unbroken vertical sync lock.

---

## RF Front-End Characterization & Empirical Tuning

To ensure a pristine, stable analog video feed across the full dynamic range:
- **Forced Sweet-Spot Gain (Mode F, Index 32)**:
  - Live testing proved that stock Wi-Fi AGC struggles with continuous analog FM: because there are no 802.11 packet preambles, the AGC watchdog stays at maximum gain or hunts erratically. With 200 mW at close range (10–20 cm), the 4-bit ADC was severely overdriven/clipped ($I, Q = \pm 7$).
  - Manually sweeping gain from 0 to 64 on live hardware confirmed that **Forced Gain Index 32 (`reg=0x20c053e2`)** is the optimal operating sweet spot: zero near-field clipping, no AGC hunting, and high sensitivity across room distances.
- **Full BW40 Analog Bandwidth (`phy_wifi_fbw_sel(1)`)**:
  - Narrow BW20 filtering (`fbw_sel(0)`) rolled off the second-order FM sidebands of the 3.58 MHz NTSC subcarrier ($\approx 11.16\text{ MHz}$), causing phase distortion and chroma rainbow overlay.
  - Setting `phy_wifi_fbw_sel(1)` opens the full 20 MHz analog filter, delivering razor-sharp video and significantly reducing the chroma rainbow overlay.
- **MODEM_DIAG Sample Edge Margin**:
  - Interactive testing of sample clock inversion (POS vs NEG via key `'e'`) confirmed clean video on both edges, proving wide setup/hold margin on the 40 MHz MODEM_DIAG bus.
- **Disabled PLL Tracking**: Compiled with `CONFIG_ESP_PHY_DISABLE_PLL_TRACK=y` to eliminate periodic 1.0s radio recalibration stalls.

---

## NTSC 9-Line Chroma Precession Analysis

In NTSC, one scanline lasts $63.555...\ \mu\text{s}$. At 20 MS/s discrete DAC sampling:
$$\text{Samples per line} = 63.555...\ \mu\text{s} \times 20\text{ MHz} = \mathbf{1271 + \frac{1}{9}\text{ samples}}$$
- Every scanline drifts by $\frac{1}{9}\text{ sample}$ ($5.55\text{ ns}$) relative to the discrete DAC clock grid.
- Over 9 scanlines, this accumulates to $50\text{ ns}$ (1 sample slip).
- At the NTSC subcarrier frequency ($3.58\text{ MHz}$), a 50–100 ns shift rotates subcarrier phase by $\approx 120^\circ$.
- A $120^\circ$ phase shift rotates the color wheel by $\frac{1}{3}\text{rd}$: $\mathbf{\text{Red} \to \text{Green} \to \text{Blue} \to \text{Red}}$, producing repeating 9-line horizontal color layers.
- Additionally, at Pedestal 20, negative peaks of the pre-emphasized 3.58 MHz color burst dip below 0 and are clamped at code 0, which can impair the monitor's burst PLL. Raising pedestal to 24–26 prevents burst clipping.

---

## Zero Periodic CPU & Bus Contention

- **No Periodic Telemetry**: Eliminated periodic FreeRTOS tasks and timers (`armed = 0` across all Wi-Fi timers).
- **No Periodic Cache Flushes**: Eliminated periodic `esp_cache_msync()` calls that stalled the AHB bus.
- **On-Demand Diagnostics Only**: Interactive serial console (`console_diag_task`) sleeps on `getchar()` with 0% CPU and zero AHB bus traffic.

---

## Pinout (Seeed Studio XIAO ESP32-C5)

| Signal | GPIO | Function |
|---|---|---|
| **DAC Bit 0 (LSB)** | GPIO 23 | 6-bit Resistor Ladder (R = 20k / 2R = 10k) |
| **DAC Bit 1** | GPIO 24 | Resistor Ladder |
| **DAC Bit 2** | GPIO 11 | Resistor Ladder |
| **DAC Bit 3** | GPIO 12 | Resistor Ladder |
| **DAC Bit 4** | GPIO 8  | Resistor Ladder |
| **DAC Bit 5 (MSB)** | GPIO 9  | Resistor Ladder |
| **Video Out** | Output | 75Ω terminated CVBS into monitor |

---

## Building and Flashing

### Validate Build Constraints
```bash
python tools/validate_build.py
```

### Build with Docker (ESP-IDF v6.0.2)
```powershell
docker run --rm -v "${PWD}/..:/workspace" -w /workspace/C5VRX-3 espressif/idf:v6.0.2 idf.py build
```

### Flash to Device
```bash
python tools/flash.py COM10
```

### Interactive Serial Monitor
```bash
python tools/monitor.py COM10
```
- `+` / `k`: Increase forced RF gain (steps of 2)
- `-` / `j`: Decrease forced RF gain (steps of 2)
- `a`: Restore automatic AGC
- `f`: Toggle forced gain
- `e`: Toggle RX sample edge (POS / NEG)
- `Space`: Print live GDMA ring offsets, descriptor addresses, and hardware FIFO counters.
