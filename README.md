<div align="center">
  <img src="assets/c5vrx-logo.jpg" alt="C5VRX logo" width="760" />

  <p><strong>ESP32-C5 Analog 5.8 GHz FPV Receiver</strong></p>
  <p>From live RF to real-time analog NTSC composite video with one Seeed Studio XIAO ESP32-C5 and a passive resistor DAC.</p>

  <p>
    <a href="https://twotoz.github.io/C5VRX/"><img src="https://img.shields.io/badge/Web%20Flasher-Online-1f6feb?style=flat" alt="Web Flasher" /></a>
    <a href="https://discord.gg/3YNgJRHmzD"><img src="https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&amp;logoColor=white" alt="Join the C5VRX Discord" /></a>
    <img src="https://img.shields.io/badge/status-production%20proven-success" alt="Production proven" />
    <img src="https://img.shields.io/badge/chip-ESP32--C5-111111" alt="ESP32-C5" />
    <img src="https://img.shields.io/badge/RF-5.8%20GHz%20(48%20channels)-6f42c1" alt="5.8 GHz" />
    <img src="https://img.shields.io/badge/output-analog%20CVBS%20NTSC-orange" alt="Analog CVBS" />
    <img src="https://img.shields.io/badge/architecture-Zero--EOF%20Circular%20GDMA-blueviolet" alt="Zero-EOF GDMA" />
    <img src="https://img.shields.io/badge/license-GPL--3.0--only-blue" alt="GPL-3.0-only" />
  </p>
</div>

---

## Range / demod research

The current experimental range work measures semantic CVBS sync and the exact-adjacent winding loss hidden by the 50 ns endpoint discriminator. See `docs/range-demod-quality-v2.md` for the measurement model and hardware validation rules.

The current Range v2 work is documented in:
- `docs/range-v2.md` — implementation and validation overview;
- `docs/range-v2-knowledge.md` — preserved control/demod engineering knowledge;
- `docs/range-v2-research-notes.md` — RF research hypotheses and hardware test plan.
- `docs/trajectory-v2.md` — two-bundle adjacent-trajectory demod, confidence model and PLL-lite validation plan.

## Web Flasher (Zero-Install Browser Flashing)

Flash your Seeed Studio XIAO ESP32-C5 directly from your browser (Google Chrome, Microsoft Edge, Brave, Opera) with zero installation required:

**[Open the C5VRX Web Flasher](https://twotoz.github.io/C5VRX/)**

The production web flasher is hosted entirely by **GitHub Pages** at
[twotoz.github.io/C5VRX](https://twotoz.github.io/C5VRX/). There is no VPS,
application server, or separate production web host in the current deployment.

- **Automatic Latest Firmware**: Automatically selects the newest immutable semantic-version release.
- **One-Click Flashing**: Flashes the universal merged production image (`bootloader + partitions + app` at `0x0`) over Web Serial. Firmware is mirrored into the GitHub Pages artifact and fetched same-origin, so browser CORS redirects are not part of the production flash path.
- **Selectable Releases**: The **Releases** tab contains only semantic-version releases such as `v3.0.0`, `v3.0.1`, and newer.
- **Separate PR Builds Tab**: Same-repository pull requests publish a temporary `pr-<number>` GitHub prerelease. Experimental builds appear only under **PR Builds**, never in the normal Releases list, and require an explicit warning confirmation before flashing.
- **Offline / Local Execution**: You can also run the web flasher locally:
  ```bash
  python tools/open_webflasher.py
  ```
  *(Starts a local HTTP server at `http://localhost:8080/web/index.html` and opens your browser.)*

### Automatic releases and versioning

Every push or merged PR to `main` builds the production firmware and publishes a new immutable GitHub release with a semantic version tag.

- `BREAKING CHANGE` or a conventional-commit `!` creates a **major** bump.
- `feat:` / `feat(scope):` creates a **minor** bump.
- `fix:`, `chore:`, `docs:`, and other changes create a **patch** bump.
- If no stable release exists yet, the current `v3.0.0-rc1` line is promoted to `v3.0.0`.
- The resolved version is written to `version.txt` before the ESP-IDF build, so the firmware metadata and GitHub release use the same version.
- Release assets remain attached to their immutable version tag; the old mutable `main` release/tag is retired automatically after the first versioned release succeeds.

### Website deployment

Firmware releases and website deployment are intentionally separate:

- `.github/workflows/build.yml` validates and builds firmware, then publishes a versioned release after a successful push to `main`. For same-repository PRs it also maintains a clearly marked temporary prerelease (`pr-<number>`) and removes it when the PR closes.
- `.github/workflows/deploy-web.yml` is the **only production website deployment**. It always checks out trusted `main`, then packages the web flasher plus a generated firmware mirror into one GitHub Pages artifact.
- `tools/prepare_pages_site.sh` mirrors the newest semantic firmware releases and all active `pr-<number>` prereleases under `firmware/<tag>/`, and generates `firmware/releases.json`.
- The browser reads that Pages manifest and downloads binaries from the same `twotoz.github.io` origin. This avoids GitHub Release storage CORS redirects entirely.
- Successful Production CI triggers a Pages mirror refresh, so newly published/updated PR builds and releases become available without deploying unmerged PR web code.
- When a PR closes or merges, CI deletes its temporary prerelease/tag; the next successful cleanup-triggered Pages refresh removes it from the mirror.

---

## Community

Questions, build photos, feedback, or development discussion? **[Join the C5VRX Discord](https://discord.gg/3YNgJRHmzD)**.

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

### 3. Fixed BW40 Analog Front-End
- **BW40 is the production RF contract**: C5VRX keeps the wide analog front-end selected with `phy_wifi_fbw_sel(1)` during startup and after every channel retune.
- **No runtime BW20 gearbox**: Earlier hardware testing showed the narrower setting rolls off part of the analog-FM video spectrum, reducing detail and causing chroma instability. The later theoretical "+3 dB survival" gearbox was therefore removed.
- **No bandwidth-switch transient in flight**: Weak-signal recovery is handled by the adaptive gain controller and demodulator/noise handling while RF bandwidth remains fixed.

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
3. **BOOT Button**: The built-in BOOT button (GPIO 28) switches channels on short click. A long press opens the standalone PAL/NTSC menu; short presses move between pages and a long press applies the selected action. On the CHANNEL page, a long press scans all 48 channels and selects the strongest coherent carrier.
4. **Persistent settings**: Channel, RF bandwidth mode, AFC/output/video-standard modes, AGC/manual gain and the BOOT-menu preference are stored in NVS and restored after restart.

---

## Interactive Serial Console Hotkeys

Connecting to the USB serial console (115200 baud) provides live telemetry and single-key controls:

| Key | Action |
|:---:|:---|
| `c` / `C` | Cycle FPV channel / band (48 standard channels: RaceBand, Boscam A/B/E, FatShark, LowBand) |
| `+` / `-` | Manual RF gain step (±2 index) |
| `a` / `s` / `m` | Switch AGC mode: **Active** (auto-adapting) / **Shadow** (dry-run) / **Manual** (fixed) |
| `f` | Cycle AFC Mode: **Auto Centering** (±1.5 MHz) / **Hold** / **Off** (0 kHz) |
| `,` / `.` | Fine-tune carrier frequency offset in ±50 kHz steps |
| `0` | Reset frequency offset to 0 kHz |
| `e` | Toggle RX sample clock edge (POS / NEG) |
| `d` | Print real-time reception diagnostics summary |

---

## Build & Flash Guide

### Prerequisites
- **Option A (Docker - Recommended)**: Docker Desktop or Docker engine installed.
- **Option B (Native ESP-IDF)**: [ESP-IDF v6.0.x](https://docs.espressif.com/projects/esp-idf/en/v6.0/esp32c5/get-started/) installed with Python 3.10+.

---

### Step 1: Build the Firmware

#### Option A: Build via Docker (Zero-Install Toolchain)
No ESP-IDF installation required on your host machine. Run from the repository root:

**Linux / macOS / Git Bash:**
```bash
docker run --rm -v "${PWD}:/workspace" -w /workspace espressif/idf:v6.0.2 idf.py build
```

**Windows PowerShell:**
```powershell
docker run --rm -v "${PWD}:/workspace" -w /workspace espressif/idf:v6.0.2 idf.py build
```

#### Option B: Build with Native ESP-IDF v6.0+
If you have ESP-IDF installed locally:

**Linux / macOS:**
```bash
. $IDF_PATH/export.sh
idf.py build
```

**Windows (ESP-IDF PowerShell Environment):**
```powershell
export.ps1
idf.py build
```

The build produces three critical binaries in `build/`:
- `build/bootloader/bootloader.bin` (at flash offset `0x2000`)
- `build/partition_table/partition-table.bin` (at flash offset `0x8000`)
- `build/c5vrx3.bin` (at flash offset `0x10000`)

---

### Step 2: Verify Architectural Constraints
Before flashing, run the built-in validator to ensure zero DMA/BitScrambler constraint violations:
```bash
python tools/validate_build.py
```
*(All architectural checks must pass.)*

---

### Step 3: Flash to ESP32-C5

#### Option A: Web Flasher (Zero-Install In-Browser Flasher)
Launch the web flasher directly in your browser (Google Chrome, Microsoft Edge, Brave):
**[Open C5VRX Web Flasher on GitHub Pages](https://twotoz.github.io/C5VRX/)**

#### Option B: Zero-Friction Auto-Flash (Python Watcher)
Run the auto-flash watcher:
```bash
python tools/auto_flash.py
```
*Plug in or reset your Seeed Studio XIAO ESP32-C5 into download mode (hold BOOT while tapping RESET), and the watcher will detect the COM port, flash the firmware, and automatically trigger a watchdog reset into the application!*

#### Option C: Direct Flash Script
Specify your COM port (or omit to auto-detect):
```bash
python tools/flash.py COM10
```

#### Option D: Native ESP-IDF Flasher
```bash
idf.py -p COM10 flash
```

---

### Step 4: Interactive Serial Monitor & Diagnostics
Launch the dedicated low-latency serial monitor:
```bash
python tools/monitor.py COM10
```
Use the interactive hotkeys (`c` to cycle channels, `+`/`-` for manual gain, `a` for active AGC, `d` for hardware diagnostics).

---

## Repository Structure

```text
├── CMakeLists.txt             # Production top-level ESP-IDF project
├── sdkconfig.defaults         # Production build configuration (ESP32-C5 @ 240MHz)
├── partitions.csv             # Custom minimal partition table
├── main/                      # Standalone C5VRX-3 production firmware
│   ├── CMakeLists.txt         # Component manifest & BitScrambler registration
│   ├── main.c                 # Application entry point
│   ├── rf.c / rf.h            # Wi-Fi PHY RX-only frontend & frequency tuning
│   ├── video.c / video.h      # Realtime PARLIO RX/TX, Zero-EOF GDMA & AGC engine
│   ├── fm.bsasm               # Phase5 BitScrambler demodulator program
│   └── osd_font.h             # 8x8 font tables for OSD
├── web/                       # Zero-install Betaflight-style Web Flasher (Web Serial API)
│   ├── index.html             # Flasher dashboard UI
│   ├── style.css              # Dark slate theme with blue accents & white topbar
│   ├── app.js                 # Web Serial flasher & release management logic
│   └── esptool.js             # Vendored esptool-js client with ESP32-C5 support
├── tools/                     # Production validation & flashing utilities
│   ├── open_webflasher.py     # Local offline Web Flasher launcher & HTTP server
│   ├── validate_build.py      # Architectural constraint validator
│   ├── auto_flash.py          # Auto-detecting flashing watcher
│   ├── flash.py               # One-click direct flasher
│   ├── monitor.py             # Low-latency interactive serial console
│   └── live_logger.py         # Real-time CSV telemetry logger
├── docs/                      # Architectural specs & mathematical proofs
└── legacy/
    ├── c5vrx1/                # Original proof-of-concept repository snapshot
    └── c5vrx2/                # Complete historical C5VRX-2 firmware, research & tools
```

---

## License

C5VRX is open-source software licensed under the **GNU General Public License v3.0 only** (`GPL-3.0-only`).

See [LICENSE](LICENSE) for full licensing terms.
