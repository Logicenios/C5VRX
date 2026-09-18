<div align="center">
  <img src="assets/c5vrx-logo.jpg" alt="C5VRX logo" width="760" />

  <p><strong>ESP32-C5 Analog 5.8 GHz FPV Receiver</strong></p>
  <p>From live RF to real-time analog NTSC composite video with one Seeed Studio XIAO ESP32-C5 and a passive resistor DAC.</p>

  <p>
    <img src="https://img.shields.io/badge/status-production%20proven-success" alt="Production proven" />
    <img src="https://img.shields.io/badge/chip-ESP32--C5-111111" alt="ESP32-C5" />
    <img src="https://img.shields.io/badge/RF-5.8%20GHz%20(48%20channels)-6f42c1" alt="5.8 GHz" />
    <img src="https://img.shields.io/badge/output-analog%20CVBS%20NTSC-orange" alt="Analog CVBS" />
    <img src="https://img.shields.io/badge/architecture-Zero--EOF%20Circular%20GDMA-blueviolet" alt="Zero-EOF GDMA" />
    <img src="https://img.shields.io/badge/license-GPL--3.0--only-blue" alt="GPL-3.0-only" />
  </p>
</div>

---

## What is C5VRX?

**C5VRX-3** turns the **Seeed Studio XIAO ESP32-C5** (ESP32-C5 RISC-V SoC) into a standalone 5.8 GHz analog video (FPV) receiver.

It captures raw Wi-Fi PHY I/Q samples directly from the 5 GHz RF front-end at 40 MS/s, demodulates Wideband FM (WBFM) in real-time hardware using the ESP32-C5 **BitScrambler**, and outputs analog NTSC composite video (CVBS) via **PARLIO TX** and a 6-bit passive resistor DAC ladder into standard 75-ohm FPV goggles or monitors.

```text
5.8 GHz Analog FPV (48 Channels)
        │
        ▼
ESP32-C5 RF / MODEM_DIAG Bus (40 MS/s Q4/I4)
        │
        ▼
PARLIO RX @ 40 MS/s (POS sample edge, pure continuous hardware GDMA)
        │
        ▼
Circular GDMA Ring (16 KiB in HP SRAM, Zero-EOF patched)
        │
        ▼
Phase5 BitScrambler Demodulator (fm.bsasm: 50 ns discriminator, embedded LUT)
        │
        ▼
PARLIO TX @ 40 MHz ([D,D] mode -> 20 MS/s unique CVBS output)
        │
        ▼
6-bit Resistor DAC Ladder + 470 pF Filter -> 75-ohm Goggles
```

After startup, the CPU does not process pixels; the entire pipeline runs continuously in dedicated silicon peripherals (AHB GDMA $\to$ BitScrambler $\to$ PARLIO TX).

---

## Key Innovations & Architectural Highlights

### 1. The Breakthrough: Zero-EOF Circular GDMA
- **The Problem**: In continuous loop mode, the stock ESP-IDF PARLIO TX driver injected a GDMA EOF (`suc_eof = 1`) on every cyclic ring wrap (confirmed in [espressif/esp-idf#19091](https://github.com/espressif/esp-idf/issues/19091)). This triggered periodic hardware stalls, causing a 1-second vertical sync drop and jagged horizontal line jitter ("kartels").
- **The Solution**: C5VRX-3 patches `dw0.suc_eof = 0` across the descriptor ring in SRAM after driver initialization, paired with 64-byte aligned cache synchronization (`sync_dma_c2m`).
- **The Result**: Truly gapless, infinite circular streaming with zero wrap bubbles, rock-solid vertical sync lock, and crystal-clear horizontal alignment.

### 2. Dual-Loop Adaptive AGC with $Q_{\text{phase}}$ Coherence Tracking
- Eliminates both the erratic hunting of stock packet AGC and the "noise trap" of blind power measurement (where background thermal noise keeps measured power elevated even in deep fades).
- Computes real-time integer FM phase coherence:
  $$Q_{\text{phase}} = \frac{\text{count}(P \ge 8 \land \text{Dot} > 0 \land |\text{Cross}| \le \text{Dot})}{255} \times 100\%$$
- **Dynamic Gain Adaptation**: As signal degrades ($Q_{\text{phase}} < 68\%$ or $P_{\text{median}} < 18$) without clipping, the receiver actively steps RF gain up towards Gain 62 to lift weak carriers above the ADC quantizer floor.
- **Fast Overload Safety Rem**: Instant gain cut ($\Delta G = -4 / -6$) if clipping occurs ($N_{\text{clip}} \ge 4$ and $P_{\text{median}} > 18$).
- **Deadband Lock**: Zero register writes when locked in the clean target zone ($Q_{\text{phase}} \ge 70\%, P_{\text{median}} \in [18, 30]$).

### 3. Dynamic Bandwidth Gearbox (BW40 <-> BW20)
- **BW40 (Wide / Color)**: Default mode keeping the full 20 MHz baseband analog filter open (`phy_wifi_fbw_sel(1)`) for vibrant color subcarrier fidelity and horizontal resolution.
- **BW20 (+3 dB Long-Range Survival)**: In severe fades ($G \ge 56$ and $Q_{\text{phase}} < 55\%$ or $P_{\text{median}} < 16$), the receiver automatically downshifts to BW20 (`phy_wifi_fbw_sel(0)`), halving thermal noise bandwidth for an immediate **$+3\text{ dB}$ SNR boost** (+41% range). Automatically upshifts back to BW40 when signal recovers.

### 4. Soft-Noise Squelched Phase5 Demodulator
- The `fm.bsasm` BitScrambler program implements soft-noise squelching: phase deltas around $\pm 180^\circ$ (deltas $-16 \dots -12$ and $+13 \dots +15$) are mapped to blanking pedestal (DAC code 20) instead of sync tip (DAC code 0).
- Eliminates false horizontal sync pulses and screen tearing during noise bursts and static.

---

## Hardware Pinout & Circuit (Seeed Studio XIAO ESP32-C5)

Connect a 6-bit binary-weighted resistor DAC ladder to the XIAO pins, meeting at the `VIDEO` node:

| XIAO Pin | ESP32-C5 GPIO | Bit Weight | Series Resistor |
|:---:|:---:|:---:|:---:|
| **D4** | GPIO 23 | Bit 0 (LSB) | 8.2 kΩ |
| **D5** | GPIO 24 | Bit 1 | 3.9 kΩ |
| **D6** | GPIO 11 | Bit 2 | 2.0 kΩ |
| **D7** | GPIO 12 | Bit 3 | 1.0 kΩ |
| **D8** | GPIO 8  | Bit 4 | 470 Ω |
| **D9** | GPIO 9  | Bit 5 (MSB) | 240 Ω |
| **GND** | GND | Ground | Ground reference |

### Recommended Analog Filters:
1. **Shunt Termination**: 200 Ω resistor from `VIDEO` to `GND`. When connected to goggles with standard 75 Ω termination, this forms a matched 0–1.0 V standard CVBS level.
2. **De-Emphasis Filter**: A **470 pF ceramic capacitor** placed in parallel across `VIDEO` and `GND` creates a 10–14 dB high-frequency de-emphasis low-pass filter, dramatically reducing triangular FM noise and snow.
3. **BOOT Button**: The built-in BOOT button (GPIO 28) switches channels on short click and toggles the OSD menu on long press (≥ 600 ms).

---

## Interactive Serial Console Hotkeys

Connecting to the USB serial console (115200 baud) provides live telemetry and single-key controls:

| Key | Action |
|:---:|:---|
| `c` / `C` | Cycle FPV channel / band (48 standard channels: RaceBand, Boscam A/B/E, FatShark, LowBand) |
| `+` / `-` | Manual RF gain step (±2 index) |
| `a` / `s` / `m` | Switch AGC mode: **Active** (auto-adapting) / **Shadow** (dry-run) / **Manual** (fixed) |
| `b` | Cycle Bandwidth Gear: **Auto Gearbox** / Forced BW40 / Forced BW20 |
| `f` | Cycle AFC Mode: **Auto Centering** (±1.5 MHz) / **Hold** / **Off** (0 kHz) |
| `,` / `.` | Fine-tune carrier frequency offset in ±50 kHz steps |
| `0` | Reset frequency offset to 0 kHz |
| `e` | Toggle RX sample clock edge (POS / NEG) |
| `d` | Print real-time reception diagnostics summary |

---

## Build & Flash

### Prerequisites
- ESP-IDF v6.0.x (or Docker `espressif/idf:v6.0.2`)
- Python 3.10+

### 1. Build via Docker (Recommended)
```bash
docker run --rm -v "${PWD}:/workspace" -w /workspace espressif/idf:v6.0.2 idf.py build
```

### 2. Verify Build Constraints
```bash
python tools/validate_build.py
```

### 3. Zero-Friction Auto-Flash
```bash
python tools/auto_flash.py
```
*(The script monitors COM ports; simply plug in or reset the XIAO ESP32-C5 into download mode and it will flash automatically!)*

---

## Repository Structure

```text
├── CMakeLists.txt             # Production top-level project
├── sdkconfig.defaults         # Production build configuration
├── partitions.csv             # Partition table
├── main/                      # Standalone C5VRX-3 firmware
│   ├── main.c                 # Application entry point
│   ├── rf.c / rf.h            # Wi-Fi PHY RX-only frontend & frequency tuning
│   ├── video.c / video.h      # Realtime PARLIO RX/TX, Zero-EOF GDMA & AGC engine
│   ├── fm.bsasm               # Phase5 BitScrambler demodulator program
│   └── osd_font.h             # 8x8 font tables for OSD
├── tools/                     # Production validation & flashing utilities
│   ├── validate_build.py      # Architectural constraint validator
│   ├── auto_flash.py          # Auto-detecting flashing watcher
│   ├── monitor.py             # Serial monitor
│   └── live_logger.py         # Real-time CSV logger
├── docs/                      # Architectural specs & mathematical proofs
├── archive/
│   └── c5vrx2/                # Complete historical C5VRX-2 firmware, research & tools
└── legacy/
    └── c5vrx1/                # Original proof-of-concept repository snapshot
```

---

## License

C5VRX is open-source software licensed under the **GNU General Public License v3.0 only** (`GPL-3.0-only`).

See [LICENSE](LICENSE) for full licensing terms.
