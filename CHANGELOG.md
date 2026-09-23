# Changelog

All notable changes to this fork are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Upstream history before the refactor is in `git log` (baseline `upstream/main` = `96446ed`).

## [Unreleased]

### Added
- Phase 3: C5 → FPGA link. `docs/FPGA_LINK.md` explains the decision. The FPGA reads the
  8 MODEM_DIAG pads directly; PARLIO RX's 40 MHz sample clock is output on GPIO10 as the
  strobe. A 1 Mbaud UART control link on GPIO11/12 uses a versioned, CRC-16-framed
  protocol (`src/link_proto.h`, `src/link.c`).
- The FPGA can set channel, scan all 48 channels with per-channel results, set a
  video-standard hint, store an opaque FPGA settings blob in NVS, and receive 10 Hz STATUS
  (gain, Q4 quality, lock, carrier offset, sync tip / blanking / sync amplitude). The C5 BOOT
  button is forwarded.
- `tools/test_link_proto.c` and `tools/link_cli.py`, a host client that stands in for the
  FPGA via a USB-UART adapter.
- `docs/MEASUREMENTS.md`: a pending lab-measurements list.
- Phase 2: PlatformIO project (`platformio.ini`, pioarduino 61.04.00-RC1, ESP-IDF 6.1.0) with
  `waveshare_c5zero_fpga` and `xiao_c5_dac` environments, per-env sdkconfig defaults, and a
  custom `boards/waveshare_esp32c5_zero.json`.
- Board layer: `src/boards/` (single board switch, pin maps, antenna switch, output
  backend), Kconfig board/antenna choice, and `board_init_early()`. The latter drives the
  C5-Zero antenna switch to external IPEX before PHY init and logs chip revision and
  antenna.
- `docs/BOARDS.md`: pin choices, strapping pins, antenna switch evidence, and the ESP32-C5
  rev v1.0 / IDF issue.
- Phase 1: `docs/THEORY.md` (single source of truth for the FM receive chain, de-emphasis,
  AFC/clamp, levels, clicks, NTSC/PAL) and `docs/MEASUREMENTS.md` (upstream hardware facts
  with sources).
- `main/video_levels.h`: post-demod sync-tip / blanking / sync-amplitude estimator, with host
  test `tools/test_video_levels.c` (NTSC + PAL synthetic FM, 4-bit quantised).
- `tools/gen_phase5_lut.py`: generates the GOLDEN BitScrambler LUT from THEORY constants.
  CI checks the embedded tables.

- Phase 0 recon: `docs/refactor/00-recon.md` covers the baseline build (ESP-IDF v6.0.2,
  1,113,280-byte app, no compiler warnings, 2 Kconfig warnings) and an architecture map of the
  RF → MODEM_DIAG → PARLIO → BitScrambler → DAC path. It also covers DSP facts checked against
  FM theory, RF gain-loop classification, a receive-only audit, dead code, stale claims and
  magic constants.
- `docs/UPSTREAM_TRIAGE.md`: verdicts for all 67 upstream issues and PRs, plus the
  hardware-measured facts and TX concerns found in them.

### Changed
- `main/` moved to `src/` (standard PlatformIO layout).
- CI builds every board with `pio run` and packages XIAO assets under the historical names
  plus `waveshare_c5zero_fpga-*` assets. The web flasher matches asset names exactly.
- `sdkconfig.defaults`: ZCMP pinned off (esp-idf#18886), cert-test PHY disabled, valid WARN
  log-level symbol, flash settings moved per board.
- GOLDEN LUT (`fm.bsasm`, `fm4.bsasm`) restored to the hardware-praised monotone rail clamp,
  replacing the unmeasured fold-back squelch from upstream `e7f38f2` (THEORY §5.5, §10).
- Default RX profile is now ARC V3, which uses raw-Q4 ADC-fill control only (THEORY §4.3).
  Video-coupled gain profiles (ARC v1, RANGE, RANGE V2, FUSION) are no longer selectable
  or restored from NVS.
- AFC AUTO uses the post-demod blanking level instead of the picture-dependent mean
  frequency (THEORY §8). The console shows S/B/A levels.
- Code comments cite THEORY/MEASUREMENTS; stale comments are corrected.

### Removed
- The `idf.py` / Docker build path, plus `tools/flash.py`, `tools/auto_flash.py` and
  `tools/package_release.py` (use `pio run -t upload`).
