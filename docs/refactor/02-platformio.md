# Phase 2 — PlatformIO and multi-board structure

Branch `refactor/phase2-platformio`, stacked on `refactor/phase1-theory`.

## Platform decision

| Candidate | ESP-IDF | Builds ESP32-C5? | Result |
|---|---|---|---|
| `platformio/espressif32 @ 7.1.3` (official, 2026-09-11) | 6.1.0 | **No** | `platform.py` enables the RISC-V toolchain only for `esp32c3/c6/s2/s3`. For `esp32c5` no `riscv32-esp-elf-gcc` is installed, so CMake fails. It also defines no C5 board. Fixing it would need a `platform_packages` override, which the plan rules out. |
| pioarduino `55.03.312-1` (stable, 2026-09-22) | 5.5.5 | Yes | Builds the current firmware (RAM 183,588 B / flash 1,106,884 B, XIAO). That would be a **downgrade** from upstream's 6.0.2. |
| **pioarduino `61.04.00-RC1`** (2026-09-23) | **6.1.0** | **Yes** | Chosen. Pinned by release URL in `platformio.ini`. |

Why 6.1.0 through a platform RC rather than the stable 5.5.5 platform:

- ESP-IDF 6.1.0 itself is a stable Espressif release, and it's the newest.
- It continues the 6.0.x line that upstream validated on hardware.
- The PARLIO TX/RX driver code that the Zero-EOF ring depends on is identical to 6.0.2
  (`parlio_tx.c` `mark_eof`/`loop_transmission`, `parlio_rx.c` `partial_rx_en`; diffed).
- Moving to 5.5.5 would downgrade, which the plan says to avoid silently.

The risk is the platform wrapper being a release candidate from today. If it causes
trouble, the fallback is a one-line change to `55.03.312-1`, which was also verified to
build.

"Better performance": the realtime path runs in DMA/PARLIO/BitScrambler hardware, so the
IDF version doesn't pace it. The only measurable difference here is size: IDF 6.1 uses
+3.1 KB RAM and +32 KB flash over 5.5.5. Runtime behaviour can only be compared on
hardware.

PlatformIO Core: the official PyPI `platformio==6.2.0` runs pioarduino. No Core fork is
needed, contrary to PR #44.

## What changed

| Change | Files |
|---|---|
| Standard layout: `main/` → `src/` (`src_dir = src`) | `git mv`; tools, CI and docs paths updated |
| `platformio.ini`: shared `[env]` + `env:waveshare_c5zero_fpga`, `env:xiao_c5_dac` | `platformio.ini` |
| Per-env sdkconfig: shared `sdkconfig.defaults` + `sdkconfig.defaults.<env>` via `-DSDKCONFIG_DEFAULTS`. The builder generates `sdkconfig.<env>`. Verified from the builder source and the generated files: board choice, flash size/mode, ZCMP and cert-test values all land per env. | `sdkconfig.defaults*`, `.gitignore` |
| Custom manifest for the C5-Zero only | `boards/waveshare_esp32c5_zero.json` |
| Board layer: Kconfig board and antenna choice; `src/boards/board.h` is the single board switch; per-board headers hold pins, DAC pins, BOOT, antenna switch and backend | `src/Kconfig.projbuild`, `src/boards/*.h` |
| `board_init_early()`: antenna switch driven and read back before any PHY init, plus chip-revision and board log | `src/board.c`, `src/main.c` |
| The MODEM_DIAG pad list has one source, where `rf.c` and `video.c` used to hold two copies | `src/rf.c`, `src/video.c` |
| `FPGA_LINK` backend: no PARLIO TX, BitScrambler, DAC or CVBS menu. The RX ring, RF/ARC control and console run. The link itself is Phase 3. | `src/video.c` (`BOARD_HAS_DAC_OUTPUT`) |
| `sdkconfig.defaults` changes: | `sdkconfig.defaults` |
| ↳ ZCMP pinned off (esp-idf#18886) | |
| ↳ `CONFIG_ESP_PHY_ENABLE_CERT_TEST=n` (receive-only) | |
| ↳ log level fixed to the valid symbol `CONFIG_LOG_DEFAULT_LEVEL_WARN` (was the unknown `…_WARNING`, which silently stayed INFO) | |
| ↳ removed the unknown `ESP_WIFI_TX_BUFFER_TYPE_DYNAMIC` | |
| ↳ flash settings moved per board; C5-Zero is 4 MB DIO | |
| CI: matrix `pio run -e <env>` for both boards, then a packaging job | `.github/workflows/build.yml` |
| Web flasher: exact asset-name matching, so board-prefixed assets are never picked | `web/app.js` |
| Validator: +5 Phase 2 checks, 148 total | `tools/validate_build.py` |
| README build section, AGENTS path | `README.md`, `AGENTS.md` |

## IDF API migration

- Both envs build on IDF 6.1.0 with **zero compiler warnings and zero deprecation
  warnings**. The remaining CMake warnings are internal to IDF (a wpa_supplicant/esp_wifi
  private include) or from the platform (unused `ESP_IDF_VERSION*` variables).
- Direct register access remains where no driver API exists:
  - `AHB_DMA.*`, and `PARL_IO.*` for the Zero-EOF ring;
  - the modem/dump registers in `rf.c`;
  - the private PHY symbols.

  The PARLIO driver doesn't expose its GDMA channel, so the `peri_sel == 9` discovery
  stays. These were compared against 6.0.2 where they depend on driver internals.

## Removed

- The `idf.py` / Docker build path: the README instructions, the CI container
  `espressif/idf:v6.0.2`, and `idf.py build`.
- `tools/flash.py`, `tools/auto_flash.py`, `tools/package_release.py`. All read `build/`
  from `idf.py` and hard-coded Windows desktop paths. Use `pio run -t upload` instead.

  The root `CMakeLists.txt` stays, because the PlatformIO ESP-IDF builder requires it.
  `idf.py build` from the root no longer finds a `main` component.

## Web flasher

- **Still works:** flashing the **XIAO DAC** build. CI publishes it under the historical
  asset names (`c5vrx3.bin`, `bootloader.bin`, `partition-table.bin`,
  `c5vrx3_merged.bin`, `flasher_args.json`, `SHA256SUMS`). The Pages mirror copies all
  assets generically. The packaging step was dry-run locally.
- **Not yet supported:** the C5-Zero images are published as `waveshare_c5zero_fpga-*`,
  but the flasher UI has no board selector, so they can't be flashed from the browser yet.
  Use `pio run -e waveshare_c5zero_fpga -t upload`. A board selector belongs with the web
  work after the FPGA link exists.
- `flasher_args.json` is now generated by CI in the IDF format; PlatformIO doesn't emit it.
- The merged image keeps upstream's `--flash-mode dio` header for the XIAO (8 MB) and uses
  DIO/4 MB for the C5-Zero.

## Receive-only additions

- Cert-test PHY library disabled.
- New evidence for recon T2: calibration code in `libphy` (`phy_tx_cal.o`, `phy_rx_cal.o`,
  `phy_pwdet.o`) calls `phy_start_tx_tone_step`. RX calibration uses an internal TX tone.
  It's unchanged from upstream and still needs your spectrum check at boot.

## Build results (IDF 6.1.0, pioarduino 61.04.00-RC1)

| Env | Flash (app) | Static RAM (PlatformIO count) | Warnings |
|---|---:|---:|---:|
| `waveshare_c5zero_fpga` | 1,106,306 B of 4 MB | 186,656 B | 0 |
| `xiao_c5_dac` | 1,126,530 B of 8 MB | 186,672 B | 0 |

Checks:
- `validate_build.py` 148/148.
- 9/9 host C tests.
- `gen_phase5_lut --check`.
- Trajectory v2 LUT unchanged.
- `range_demod_bench` self-test.
- `bash -n prepare_pages_site.sh`.

## Unverified

- The C5-Zero boots at all: IDF 6.1.0 on your silicon revision, DIO flash, in-package flash.
- The antenna switch really selects IPEX at GPIO26 = 1. This comes from Waveshare's own
  documentation, but it's untested here.
- MODEM_DIAG capture on the new pad set `{0,1,4,5,6,7,8,9}` (lane skew, bit-exactness).
- The XIAO build on IDF 6.1.0. You have no DAC hardware now, and it is compile-verified only.
- The CI workflow itself hasn't run on GitHub yet. It will on the first push of a PR branch.

## Hardware checklist for you (C5-Zero, no FPGA needed)

- [ ] `pio run -e waveshare_c5zero_fpga -t upload -t monitor`. The boot log must show:
      - `board: Waveshare ESP32-C5-Zero (FPGA link) | chip: ESP32-C5 rev vX.Y`
        (tell me the revision);
      - `antenna: EXTERNAL (IPEX) (GPIO26=1, set before PHY init)`;
      - `RF ready: 5865 MHz …`;
      - the banner `Output: FPGA link (Phase 3 pending …)`.
- [ ] No reboot loop and no watchdog panic for a few minutes (esp-idf#18886 would show up
      early).
- [ ] With a VTX on A1 near the IPEX antenna, the console `p` (frequency/levels) shows
      sensible `P`/`Q` values and `Video levels … valid`. That shows capture works on the
      new pads even without the FPGA.
- [ ] Optional: IPEX antenna removed, compared with the onboard antenna (rebuild with
      `CONFIG_C5VRX_ANTENNA_ONBOARD=y`). The signal level should drop or rise
      accordingly, which confirms the polarity.
- [ ] Optional: spectrum/SDR near the antenna during boot (recon T2 / T3).
